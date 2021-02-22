using Pkg

using YAXArrays
using BenchmarkTools

const SUITE = BenchmarkGroup()
SUITE["mapCube"] = include("bench_mapcube.jl")
