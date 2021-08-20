import pyximport; pyximport.install()

from torch import multiprocessing as mp

from alphazero.Coach import Coach, get_args
from alphazero.NNetWrapper import NNetWrapper as nn
from alphazero.envs.connect4.Connect4Game import Connect4Game as Game
from alphazero.GenericPlayers import RawMCTSPlayer
from alphazero.utils import dotdict

args = get_args(dotdict({
    'run_name': 'connect4_fpu',
    'workers': mp.cpu_count(),
    'startIter': 1,
    'numIters': 1000,
    'numWarmupIters': 1,
    'process_batch_size': 2048,
    'train_batch_size': 1024,
    # should preferably be a multiple of process_batch_size and workers
    'gamesPerIteration': 2048 * mp.cpu_count(),
    'symmetricSamples': True,
    'skipSelfPlayIters': None,
    'selfPlayModelIter': 35,
    'numMCTSSims': 200,
    'numFastSims': 40,
    'probFastSim': 0.75,
    'compareWithBaseline': True,
    'arenaCompareBaseline': 512,
    'arenaCompare': 512,
    'arena_batch_size': 128,
    'arenaTemp': 1,
    'arenaMCTS': True,
    'baselineCompareFreq': 1,
    'compareWithPast': True,
    'pastCompareFreq': 1,
    'cpuct': 4,
    'fpu_reduction': 0.4,
    'load_model': True,
}),
    model_gating=True,
    max_gating_iters=None,
    max_moves=42,

    lr=0.01,
    num_channels=128,
    depth=8,
    value_head_channels=32,
    policy_head_channels=32,
    value_dense_layers=[1024, 256],
    policy_dense_layers=[1024]
)


def raw_mcts_player():
    return RawMCTSPlayer(Game, args)


args.scheduler_args.milestones = [75, 150]
args.baselineTester = raw_mcts_player


if __name__ == "__main__":
    nnet = nn(Game, args)
    c = Coach(Game, nnet, args)
    c.learn()
