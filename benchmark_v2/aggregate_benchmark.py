import arkouda as ak
import pytest


def setup_agg(t="int"):
    cfg = ak.get_config()
    N = pytest.problem_size * cfg["numLocales"]

    # Sort keys so that aggregations will not have to permute values
    # We just want to measure aggregation time, not gather
    keys = ak.sort(ak.randint(0, 2**32, N, seed=pytest.seed))
    intvals = ak.randint(0, 2**16, N, seed=(pytest.seed + 1 if pytest.seed is not None else None))
    g = ak.GroupBy(keys, assume_sorted=True)

    if t == "int":
        return g, intvals
    else:
        boolvals = (intvals % 2) == 0
        return g, boolvals


def run_agg(g, vals, op):
    g.aggregate(vals, op)

    return vals.size + vals.itemsize


@pytest.mark.benchmark(group="GroupBy.aggregate")
@pytest.mark.parametrize("op", ak.GroupBy.Reductions)
def bench_aggs(benchmark, op):
    if op in ["any", "all"]:
        g, vals = setup_agg("bool")
    else:
        g, vals = setup_agg()

    numBytes = benchmark.pedantic(run_agg, args=(g, vals, op), rounds=pytest.num_trials)

    benchmark.extra_info["Problem size"] = pytest.problem_size
    benchmark.extra_info["Bytes per second"] = "{:.4f} GiB/sec".format(
        (numBytes / benchmark.stats["mean"]) / 2 ** 30)
    benchmark.extra_info["Description"] = f"This benchmark tests GroupBy Aggregation using the {op} operator."
