module BenchMapCube

using YAXArrays
using BenchmarkTools
using Statistics
using Random

suite = BenchmarkGroup()

suite["small"] = @benchmarkable mapslices(identity, YAXArray(a), dims="Dim_1") setup=(a=rand(10,10,10))

end
BenchMapCube.suite