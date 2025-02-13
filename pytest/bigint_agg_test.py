import numpy as np
import arkouda as ak

SIZE = 5


def gather_scatter(a):
    rev = ak.array(np.arange(len(a) - 1, -1, -1))
    a2 = a[rev]
    res = ak.zeros(len(a), dtype=a.dtype)
    res[:] = a2
    res[rev] = a2
    return res


def test_negative():
    # test with negative bigint values
    arr = -1 * ak.randint(0, 2**32, SIZE)
    bi_neg = ak.cast(arr, ak.bigint)
    res = gather_scatter(bi_neg)
    assert (bi_neg.to_list() == res.to_list())


def test_large():
    # test with 256 bit bigint values
    top_bits = ak.randint(0, 2**32, SIZE, dtype=ak.uint64)
    mid_bits1 = ak.randint(0, 2**32, SIZE, dtype=ak.uint64)
    mid_bits2 = ak.randint(0, 2**32, SIZE, dtype=ak.uint64)
    bot_bits = ak.randint(0, 2**32, SIZE, dtype=ak.uint64)
    bi_arr = ak.bigint_from_uint_arrays([top_bits, mid_bits1, mid_bits2, bot_bits])
    res = gather_scatter(bi_arr)
    assert (bi_arr.to_list() == res.to_list())


def test_zero():
    # test all zero bigint assignments
    all_zero = ak.zeros(SIZE, dtype=ak.bigint)
    res = gather_scatter(all_zero)
    assert (all_zero.to_list() == res.to_list())


def test_variable_sized():
    # 5 bigints of differing number of limbs
    bits1 = ak.array([0, 0, 0, 0, 1], dtype=ak.uint64)
    bits2 = ak.array([0, 0, 0, 1, 1], dtype=ak.uint64)
    bits3 = ak.array([0, 0, 1, 1, 1], dtype=ak.uint64)
    bits4 = ak.array([0, 1, 1, 1, 1], dtype=ak.uint64)
    bits5 = ak.array([1, 1, 1, 1, 1], dtype=ak.uint64)
    bi_arr = ak.bigint_from_uint_arrays([bits1, bits2, bits3, bits4, bits5])
    res = gather_scatter(bi_arr)
    assert (bi_arr.to_list() == res.to_list())


def test_change_size():
    # Go from 256 bigint values down to just 1
    bits = ak.randint(0, 2**32, SIZE, dtype=ak.uint64)
    bi_arr = ak.bigint_from_uint_arrays([bits, bits, bits, bits])
    res = ak.ones_like(bi_arr)
    bi_arr[:] = res
    assert (bi_arr.to_list() == res.to_list())
