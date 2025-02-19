# cython: language_level=3
import numpy as np

from alphazero.Game import GameState
from alphazero.GenericPlayers import BasePlayer
from alphazero.SelfPlayAgent import SelfPlayAgent
from alphazero.pytorch_classification.utils import Bar, AverageMeter
from alphazero.utils import dotdict, get_game_results

from typing import Callable, List, Tuple, Optional
from enum import Enum
from queue import Empty

import torch.multiprocessing as mp
import torch
import random
import time


class _PlayerWrapper:
    def __init__(self, player, index):
        self.player = player
        self.index = index
        self.wins = 0
        self.winrate = 0

    def __call__(self, *args, **kwargs):
        return self.player(*args, **kwargs)

    def update(self, *args, **kwargs):
        self.player.update(*args, **kwargs)

    def reset(self):
        self.player.reset()

    def reset_wins(self):
        self.wins = 0
        self.winrate = 0

    def add_win(self):
        self.wins += 1

    def update_winrate(self, draws, num_games):
        if not num_games:
            self.winrate = 0
        else:
            self.winrate = (self.wins + 0.5 * draws) / num_games


class ArenaState(Enum):
    STANDBY = 0
    INIT = 1
    PLAY_GAMES = 2
    SINGLE_GAME = 3


def _set_state(state: ArenaState):
    def decorator(func):
        def wrapper(self, *args, **kwargs):
            if not hasattr(self, 'state') or self.state == ArenaState.STANDBY:
                self.state = state
            ret = func(self, *args, **kwargs)
            self.state = ArenaState.STANDBY
            return ret
        return wrapper
    return decorator


class Arena:
    """
    An Arena class where any game's agents can be pit against each other.
    """

    @_set_state(ArenaState.INIT)
    def __init__(
            self,
            players: List[BasePlayer],
            game_cls,
            use_batched_mcts=True,
            display: Callable[[GameState, Optional[int]], None] = None,
            args: dotdict = None
    ):
        """
        Input:
            player 1,2: two functions that takes board as input, return action
            game: Game object
            display: a function that takes board as input and prints it (e.g.
                     display in othello/OthelloGame). Is necessary for verbose
                     mode.

        see othello/OthelloPlayers.py for an example. See pit.py for pitting
        human players/other baselines with each other.
        """
        num_players = game_cls.num_players()
        if len(players) != num_players:
            raise ValueError('Argument `players` must have the same amount of players as the game supports. '
                             f'Got {len(players)} player agents, while the game requires {num_players}')

        self.__players = None
        self.players = players
        self.game_cls = game_cls
        self.use_batched_mcts = use_batched_mcts
        self.display = display
        self.args = args.copy()
        self.games_played = 0
        self.total_games = 0
        self.eps_time = 0
        self.total_time = 0
        self.eta = 0
        self.game_state = None
        self.draws = 0
        self.winrates = []
        self._agents = []
        self.stop_event = mp.Event()
        self.pause_event = mp.Event()

    @property
    def players(self):
        return self.__players

    @players.setter
    def players(self, value):
        self.__players = value
        self.__init_players()

    def __init_players(self):
        new_players = []
        for i, player in enumerate(self.__players):
            if not isinstance(player, _PlayerWrapper):
                player = _PlayerWrapper(player, i)
            new_players.append(player)
        self.__players = new_players

    def __reset_counts(self):
        self.draws = 0
        self.winrates = []
        [player.reset_wins() for player in self.players]

    def __update_winrates(self):
        num_games = sum([player.wins for player in self.players]) + (
            self.draws if self.args.use_draws_for_winrate else 0
        )
        [player.update_winrate(
            self.draws if self.args.use_draws_for_winrate else 0, num_games
        ) for player in self.players]
        self.winrates = [player.winrate for player in self.__sorted_players()]

    def __sorted_players(self):
        return iter(sorted(self.players, key=lambda p: p.index))

    @_set_state(ArenaState.SINGLE_GAME)
    def play_game(self, verbose=False, _player_to_index: list = None) -> Tuple[GameState, np.ndarray]:
        """
        Executes one episode of a game.

        Returns:
            state: the last state in the game
            result: the value of the game result (based on last state)
        """
        if verbose: assert self.display

        self.stop_event = mp.Event()
        self.pause_event = mp.Event()

        # Reset the state of the players if needed
        [p.reset() for p in self.players]
        self.game_state = self.game_cls()
        player_to_index = _player_to_index or list(range(self.game_state.num_players()))

        while not self.stop_event.is_set():
            while self.pause_event.is_set():
                time.sleep(.1)

            action = self.players[player_to_index[self.game_state.player]](self.game_state)

            # valids = state.valid_moves()
            # assert valids[action] > 0, ' '.join(map(str, [action, index, state.player, turns, valids]))

            if verbose:
                print(f'Turn {self.game_state.turns}, Player {self.game_state.player}')

            [p.update(self.game_state, action) for p in self.players]
            self.game_state.play_action(action)

            if verbose:
                self.display(self.game_state, action)
            
            winstate = self.game_state.win_state()

            if winstate.any():
                if verbose:
                    print(f'Game over: Turn {self.game_state.turns}, Result {winstate}')
                    self.display(self.game_state)

                return self.game_state, winstate

        return self.game_state, self.game_state.win_state()

    @_set_state(ArenaState.PLAY_GAMES)
    def play_games(self, num: int, verbose=False, shuffle_players=True) -> Tuple[List[int], int, List[int]]:
        """
        Plays num games in which the order of the players
        is randomized for each game. The order is simply switched
        if there are only two players.

        Returns:
            wins: number of wins for each player in self.players
            draws: number of draws that occurred in total
            winrates: the win rates for each player in self.players
        """
        self.total_games = num
        self.stop_event = mp.Event()
        self.pause_event = mp.Event()
        eps_time = AverageMeter()
        bar = Bar('Arena.play_games', max=num)
        end = time.time()
        self.__reset_counts()

        players = list(range(self.game_cls.num_players()))

        def get_player_order():
            if not shuffle_players: return
            if len(players) == 2:
                players.reverse()
            else:
                random.shuffle(players)

        if self.use_batched_mcts:
            self.args.gamesPerIteration = num
            self._agents = []
            policy_tensors = []
            value_tensors = []
            batch_ready = []
            batch_queues = []
            self.stop_event = mp.Event()
            self.pause_event = mp.Event()
            ready_queue = mp.Queue()
            result_queue = mp.Queue()
            completed = mp.Value('i', 0)
            games_played = mp.Value('i', 0)

            # self.args.expertValueWeight.current = self.args.expertValueWeight.start
            # if self.args.workers >= mp.cpu_count():
            #    self.args.workers = mp.cpu_count() - 1

            for i in range(self.args.workers):
                get_player_order()
                input_tensors = [[] for _ in players]
                batch_queues.append(mp.Queue())

                policy_tensors.append(torch.zeros(
                    [self.args.arena_batch_size, self.game_cls.action_size()]
                ))
                policy_tensors[i].share_memory_()

                value_tensors.append(torch.zeros([self.args.arena_batch_size, self.game_cls.num_players() + 1]))
                value_tensors[i].share_memory_()

                batch_ready.append(mp.Event())
                if self.args.cuda:
                    policy_tensors[i].pin_memory()
                    value_tensors[i].pin_memory()

                self._agents.append(
                    SelfPlayAgent(i, self.game_cls, ready_queue, batch_ready[i],
                                  input_tensors, policy_tensors[i], value_tensors[i], batch_queues[i],
                                  result_queue, completed, games_played, self.stop_event, self.pause_event, self.args,
                                  _is_arena=True, _player_order=players.copy()))
                self._agents[i].daemon = True
                self._agents[i].start()

            sample_time = AverageMeter()
            end = time.time()

            n = 0
            while completed.value != self.args.workers:
                try:
                    id = ready_queue.get(timeout=1)

                    policy = []
                    value = []
                    data = batch_queues[id].get()
                    for player in range(len(self.players)):
                        batch = data[player]
                        if not isinstance(batch, list):
                            p, v = self.players[player](batch)
                            policy.append(p.to(policy_tensors[id].device))
                            value.append(v.to(value_tensors[id].device))

                    policy_tensors[id].copy_(torch.cat(policy))
                    value_tensors[id].copy_(torch.cat(value))
                    batch_ready[id].set()
                except Empty:
                    pass

                size = games_played.value
                if size > n:
                    sample_time.update((time.time() - end) / (size - n), size - n)
                    n = size
                    end = time.time()

                wins, draws, _ = get_game_results(
                    result_queue,
                    self.game_cls,
                    _get_index=lambda p, i: self._agents[i].player_to_index[p]
                )
                for i, w in enumerate(wins):
                    self.players[i].wins += w
                self.draws += draws
                self.__update_winrates()

                bar.suffix = '({eps}/{maxeps}) Winrates: {wr} | Eps Time: {et:.3f}s | Total: {total:} | ETA: {eta:}' \
                    .format(
                        eps=size, maxeps=num, et=sample_time.avg, total=bar.elapsed_td, eta=bar.eta_td,
                        wr=[round(w, 2) for w in self.winrates]
                    )
                bar.goto(size)

                self.games_played = size
                self.eps_time = sample_time.avg
                self.total_time = bar.elapsed_td
                self.eta = bar.eta_td

            self.stop_event.set()
            bar.update()
            bar.finish()

            for _ in range(ready_queue.qsize()):
                try:
                    ready_queue.get_nowait()
                except Empty:
                    break

            for _ in range(result_queue.qsize()):
                try:
                    result_queue.get_nowait()
                except Empty:
                    break

            for queue in batch_queues:
                for _ in range(queue.qsize()):
                    try:
                        queue.get_nowait()
                    except Empty:
                        break

            for agent in self._agents:
                agent.join()
                del policy_tensors[0]
                del value_tensors[0]
                del batch_ready[0]

        else:
            for eps in range(1, num + 1):
                if self.stop_event.is_set():
                    break

                # Get a new lookup for self.players, randomized or reversed from original
                get_player_order()

                # Play a single game with the current player order
                _, winstate = self.play_game(verbose, players)
                if self.stop_event.is_set():
                    break

                # Bookkeeping + plot progress
                for player, is_win in enumerate(winstate):
                    if is_win:
                        if player == len(winstate) - 1:
                            self.draws += 1
                        else:
                            self.players[players[player]].add_win()

                self.__update_winrates()
                eps_time.update(time.time() - end)
                end = time.time()
                bar.suffix = '({eps}/{maxeps}) Winrates: {wr} | Eps Time: {et:.3f}s | Total: {total:} | ETA: {eta:}' \
                    .format(
                        eps=eps, maxeps=num, et=eps_time.avg, total=bar.elapsed_td, eta=bar.eta_td,
                        wr=[round(w, 2) for w in self.winrates]
                    )
                bar.next()
                self.games_played = eps
                self.eps_time = eps_time.avg
                self.total_time = bar.elapsed_td
                self.eta = bar.eta_td

            bar.update()
            bar.finish()

        wins = [player.wins for player in self.__sorted_players()]

        return wins, self.draws, self.winrates
