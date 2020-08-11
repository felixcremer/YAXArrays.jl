"""
The functions provided by YAXArrays are supposed to work on different types of cubes. This module defines the interface for all
Data types that
"""
module Cubes
using DiskArrays: DiskArrays, eachchunk
using Distributed: myid
using Dates: TimeType
using IntervalSets: Interval, (..)
using Base.Iterators: take, drop
using ..YAXArrays: workdir, YAXDefaults
using YAXArrayBase: YAXArrayBase, iscompressed, dimnames
import YAXArrayBase: getattributes, iscontdim, dimnames, dimvals


"""
    readcubedata(cube)

Given any array implementing the YAXArray interface it returns an in-memory [`YAXArray`](@ref) from it.
"""
function readcubedata(x)
  YAXArray(collect(CubeAxis,caxes(x)),getindex_all(x),getattributes(x))
end

"""
This function calculates a subset of a cube's data
"""
function subsetcube end

"Returns the axes of a Cube"
function caxes end

"Chunks, if given"
function cubechunks(c) end

"Offset of the first chunk"
function chunkoffset(c) end

include("Axes.jl")
using .Axes: CubeAxis, RangeAxis, CategoricalAxis, findAxis, getAxis, axVal2Index,
  axname, axsym, axVal2Index_lb, axVal2Index_ub, renameaxis, axcopy

mutable struct CleanMe
  path::String
  persist::Bool
  function CleanMe(path::String,persist::Bool)
    c = new(path,persist)
    finalizer(clean,c)
    c
  end
end
function clean(c::CleanMe)
  if !c.persist && myid()==1
    if !isdir(c.path)
      @warn "Cube directory $(c.path) does not exist. Can not clean"
    else
      rm(c.path,recursive=true)
    end
  end
end

"""
    YAXArray{T,N}

An array labelled with named axes that have values associated with them.
It can wrap normal arrays or, more typically DiskArrays.

### Fields

* `axes` a `Vector{CubeAxis}` containing the Axes of the Cube
* `data` N-D array containing the data
"""
struct YAXArray{T,N,A<:AbstractArray{T,N},AT}
  axes::AT
  data::A
  properties::Dict{String}
  cleaner::Vector{CleanMe}
end

YAXArray(axes,data,properties=Dict{String,Any}(); cleaner=CleanMe[]) = YAXArray(axes,data,properties, cleaner)
function YAXArray(x::AbstractArray)
  ax = caxes(x)
  props = getattributes(x)
  YAXArray(ax,x,props)
end
Base.size(a::YAXArray) = size(a.data)
Base.size(a::YAXArray,i::Int) = size(a.data,i)
Base.permutedims(c::YAXArray,p)=YAXArray(c.axes[collect(p)],permutedims(c.data,p),c.properties,c.cleaner)
caxes(c::YAXArray)=c.axes
function caxes(x)
  map(enumerate(dimnames(x))) do a
    i,s = a
    v = YAXArrayBase.dimvals(x,i)
    iscontdim(x,i) ? RangeAxis(s,v) : CategoricalAxis(s,v)
  end
end
cubechunks(c::YAXArray)=common_size(eachchunk(c.data))
cubechunks(x) = common_size(eachchunk(x))
common_size(a::DiskArrays.GridChunks) = a.chunksize
function common_size(a)
  ntuple(ndims(a)) do idim
    otherdims = setdiff(1:ndims(a),idim)
    allengths = map(i->length(i.indices[idim]),a)
    for od in otherdims
      allengths = unique(allengths,dims=od)
    end
    @assert length(allengths) == size(a,idim)
    length(allengths)<3 ? allengths[1] : allengths[2]
  end
end

getindex_all(a) = getindex(a,ntuple(_->Colon(),ndims(a))...)
Base.getindex(x::YAXArray, i...) = x.data[i...]
chunkoffset(c::YAXArray)=common_offset(eachchunk(c.data))
chunkoffset(x) = common_offset(eachchunk(x))
common_offset(a::DiskArrays.GridChunks) = a.offset
function common_offset(a)
  ntuple(ndims(a)) do idim
    otherdims = setdiff(1:ndims(a),idim)
    allengths = map(i->length(i[idim]),a)
    for od in otherdims
      allengths = unique(allengths,dims=od)
    end
    @assert length(allengths) == size(a,idim)
    length(allengths)<3 ? 0 : allengths[2]-allengths[1]
  end
end
readcubedata(c::YAXArray)=YAXArray(c.axes,getindex_all(c.data),c.properties,CleanMe[])

# Implementation for YAXArrayBase interface
YAXArrayBase.dimvals(x::YAXArray, i) = x.axes[i].values

function YAXArrayBase.dimname(x::YAXArray, i)
  axsym(x.axes[i])
end

YAXArrayBase.getattributes(x::YAXArray) = x.properties

YAXArrayBase.iscontdim(x::YAXArray, i) = isa(x.axes[i], RangeAxis)

YAXArrayBase.getdata(x::YAXArray) = x.data

function YAXArrayBase.yaxcreate(::Type{YAXArray},data, dimnames, dimvals, atts)
  axlist = map(dimnames, dimvals) do dn, dv
    iscontdimval(dv) ? RangeAxis(dn,dv) : CategoricalAxis(dn,dv)
  end
  YAXArray(axlist, data, atts)
end
YAXArrayBase.iscompressed(c::YAXArray)=_iscompressed(c.data)
_iscompressed(c::DiskArrays.PermutedDiskArray) = iscompressed(c.a.parent)
_iscompressed(c::DiskArrays.SubDiskArray) = iscompressed(c.v.parent)
_iscompressed(c) = YAXArrayBase.iscompressed(c)

function renameaxis!(c::YAXArray,p::Pair)
  i = findAxis(p[1],c.axes)
  c.axes[i]=renameaxis(c.axes[i],p[2])
  c
end
function renameaxis!(c::YAXArray,p::Pair{<:Any,<:CubeAxis})
  i = findAxis(p[1],c.axes)
  i === nothing && throw(ArgumentError("Axis not found"))
  length(c.axes[i].values) == length(p[2].values) || throw(ArgumentError("Length of replacement axis must equal length of old axis"))
  c.axes[i]=p[2]
  c
end

function _subsetcube end

function subsetcube(z::YAXArray{T};kwargs...) where T
  newaxes, substuple = _subsetcube(z,collect(Any,map(Base.OneTo,size(z)));kwargs...)
  newdata = view(z.data,substuple...)
  YAXArray(newaxes,newdata,z.properties,cleaner = z.cleaner)
end

sorted(x,y) = x<y ? (x,y) : (y,x)

#TODO move everything that is subset-related to its own file or to axes.jl
interpretsubset(subexpr::Union{CartesianIndices{1},LinearIndices{1}},ax) = subexpr.indices[1]
interpretsubset(subexpr::CartesianIndex{1},ax)   = subexpr.I[1]
interpretsubset(subexpr,ax)                      = axVal2Index(ax,subexpr,fuzzy=true)
function interpretsubset(subexpr::NTuple{2,Any},ax)
  x, y = sorted(subexpr...)
  Colon()(sorted(axVal2Index_lb(ax,x),axVal2Index_ub(ax,y))...)
end
interpretsubset(subexpr::NTuple{2,Int},ax::RangeAxis{T}) where T<:TimeType = interpretsubset(map(T,subexpr),ax)
interpretsubset(subexpr::UnitRange{Int64},ax::RangeAxis{T}) where T<:TimeType = interpretsubset(T(first(subexpr))..T(last(subexpr)+1),ax)
interpretsubset(subexpr::Interval,ax)       = interpretsubset((subexpr.left,subexpr.right),ax)
interpretsubset(subexpr::AbstractVector,ax::CategoricalAxis)      = axVal2Index.(Ref(ax),subexpr,fuzzy=true)


function _subsetcube(z, subs;kwargs...)
  kwargs = Dict(kwargs)
  for f in YAXDefaults.subsetextensions
    f(kwargs)
  end
  newaxes = deepcopy(collect(caxes(z)))
  foreach(kwargs) do kw
    axdes,subexpr = kw
    axdes = string(axdes)
    iax = findAxis(axdes,caxes(z))
    if isa(iax,Nothing)
      throw(ArgumentError("Axis $axdes not found in cube"))
    else
      oldax = newaxes[iax]
      subinds = interpretsubset(subexpr,oldax)
      subs2 = subs[iax][subinds]
      subs[iax] = subs2
      if !isa(subinds,AbstractVector) && !isa(subinds,AbstractRange)
        newaxes[iax] = axcopy(oldax,oldax.values[subinds:subinds])
      else
        newaxes[iax] = axcopy(oldax,oldax.values[subinds])
      end
    end
  end
  substuple = ntuple(i->subs[i],length(subs))
  inewaxes = findall(i->isa(i,AbstractVector),substuple)
  newaxes = newaxes[inewaxes]
  @assert length.(newaxes) == map(length,filter(i->isa(i,AbstractVector),collect(substuple)))
  newaxes, substuple
end


Base.getindex(a::YAXArray;kwargs...) = subsetcube(a;kwargs...)

Base.read(d::YAXArray) = getindex(d,fill(Colon(),ndims(d))...)

function formatbytes(x)
  exts=["bytes","KB","MB","GB","TB"]
  i=1
  while x>=1024
    i=i+1
    x=x/1024
  end
  return string(round(x, digits=2)," ",exts[i])
end
cubesize(c::YAXArray) where {T}=(sizeof(T))*prod(map(length,caxes(c)))
cubesize(c::YAXArray{<:Any,0})=sizeof(T)

getCubeDes(::CubeAxis)="Cube axis"
getCubeDes(::YAXArray)="YAXArray"
getCubeDes(::Type{T}) where T = string(T)
Base.show(io::IO,c::YAXArray) = show_yax(io,c)

function show_yax(io::IO,c)
    println(io,getCubeDes(c), " with the following dimensions")
    for a in caxes(c)
        println(io,a)
    end

    foreach(getattributes(c)) do p
      if p[1] in ("labels","name","units")
        println(io,p[1],": ",p[2])
      end
    end
    println(io,"Total size: ",formatbytes(cubesize(c)))
end


using Markdown
struct YAXVarInfo
  project::String
  longname::String
  units::String
  url::String
  comment::String
  reference::String
end
Base.isless(a::YAXVarInfo, b::YAXVarInfo) = isless(string(a.project, a.longname),string(b.project, b.longname))

import Base.show
function show(io::IO,::MIME"text/markdown",v::YAXVarInfo)
    un=v.units
    url=v.url
    re=v.reference
    pr = v.project
    ln = v.longname
    co = v.comment
    mdt=md"""
### $ln
*$(co)*

* **Project** $(pr)
* **units** $(un)
* **Link** $(url)
* **Reference** $(re)
"""
    mdt[3].items[1][1].content[3]=[" $pr"]
    mdt[3].items[2][1].content[3]=[" $un"]
    mdt[3].items[3][1].content[3]=[" $url"]
    mdt[3].items[4][1].content[3]=[" $re"]
    show(io,MIME"text/markdown"(),mdt)
end
show(io::IO,::MIME"text/markdown",v::Vector{YAXVarInfo})=foreach(x->show(io,MIME"text/markdown"(),x),v)

"""
    cubeinfo(cube)

Shows the metadata and citation information on variables contained in a cube.
"""
function cubeinfo(ds::YAXArray, variable="unknown")
    p = ds.properties
    vi=YAXVarInfo(
      get(p,"project_name", "unknown"),
      get(p,"long_name",variable),
      get(p,"units","unknown"),
      get(p,"url","no link"),
      get(p,"comment",variable),
      get(p,"references","no reference")
    )
end

include("TransformedCubes.jl")
include("Slices.jl")
end
