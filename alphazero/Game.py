from abc import ABC, abstractmethod
from typing import List, Tuple, Any

import numpy as np


class GameState(ABC):
    def __init__(self, board):
        self._board = board
        self._player = 0
        self._turns = 0

    def __str__(self) -> str:
        return f'Player:\t{self._player}\n{self._board}\n'

    @abstractmethod
    def __eq__(self, other: 'GameState') -> bool:
        """Compare the current game state to an other"""
        pass

    @abstractmethod
    def clone(self) -> 'GameState':
        """Return a new clone of the game state, independent of the current one."""
        pass

    @staticmethod
    @abstractmethod
    def action_size() -> int:
        """The size of the action space for the game"""
        pass

    @staticmethod
    @abstractmethod
    def observation_size() -> Tuple[int, int, int]:
        """
        Returns:
            observation_size: the shape of observations of the current state,
                             must be in the form channels x width x height.
                             If only one plane is needed for observation, use 1 for channels.
        """
        pass

    @abstractmethod
    def valid_moves(self) -> np.ndarray:
        """Returns a numpy binary array containing zeros for invalid moves and ones for valids."""
        pass

    @staticmethod
    @abstractmethod
    def num_players() -> int:
        """
        Returns:
            num_players: the number of total players participating in the game.
        """
        pass

    @property
    def player(self) -> int:
        return self._player

    @property
    def turns(self) -> int:
        return self._turns

    def _next_player(self, player, turns=1) -> int:
        return (player + turns) % self.num_players()

    def _update_turn(self) -> None:
        """Should be called at the end of play_action"""
        self._player = self._next_player(self._player)
        self._turns += 1

    @abstractmethod
    def play_action(self, action: int) -> None:
        """Play the action in the current state given by argument action."""
        pass

    @abstractmethod
    def win_state(self) -> np.ndarray:
        """
        Get the win state of the game, a numpy array of boolean values
        for each player indicating if they have won, plus one more
        boolean at the end to indicate a draw.
        """
        pass

    @abstractmethod
    def observation(self) -> np.ndarray:
        """Get an observation from the game state in the form of a numpy array with the size of self.observation_size"""
        pass

    @abstractmethod
    def symmetries(self, pi) -> List[Tuple[Any, np.ndarray]]:
        """
        Args:
            pi: the current policy for the given canonical state

        Returns:
            symmetries: list of state, pi pairs for symmetric samples of
                        the given state and pi (ex: mirror, rotation).
                        This is an optional method as symmetric samples
                        can be disabled for training.
        """
        pass
