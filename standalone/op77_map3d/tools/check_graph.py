import json, sys, numpy as np, networkx as nx
out = sys.argv[1]
m = json.load(open(out + '/manifest.json'))['roads']
blob = open(out + '/roads.bin', 'rb').read()


def arr(name):
    a = m['arrays'][name]
    return np.frombuffer(blob, dtype=np.dtype(a['type']), count=a['length'], offset=a['offset'])


start, lanes, off, cnt, pts = arr('outStart'), arr('outLanes'), arr('laneOffset'), arr('laneCount'), arr('points').reshape(-1, 3)
n = len(off)
G = nx.DiGraph()
G.add_nodes_from(range(n))
for i in range(n):
    for j in lanes[start[i]:start[i + 1]]:
        G.add_edge(i, int(j))
scc = sorted(nx.strongly_connected_components(G), key=len, reverse=True)
print('lanes', n, 'edges', G.number_of_edges(), 'SCC sizes', [len(c) for c in scc[:8]], 'singletons', sum(1 for c in scc if len(c) == 1))
big = scc[0]
# where are the lanes outside the main component
outside = [i for i in range(n) if i not in big]
cent = np.array([pts[off[i]:off[i] + cnt[i]].mean(0) for i in outside]) if outside else np.zeros((0, 3))
print('outside main SCC', len(outside), 'dead ends (no out)', int(sum(1 for i in range(n) if start[i] == start[i + 1])))
if len(cent):
    print('outside bbox', cent.min(0).round(0), cent.max(0).round(0))
