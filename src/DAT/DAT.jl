module DAT
export registerDATFunction, mapCube, getInAxes, getOutAxes, findAxis, reduceCube
importall ..Cubes
importall ..CubeAPI
importall ..CubeAPI.CachedArrays
importall ..CABLABTools
importall ..Cubes.TempCubes
import ...CABLAB
import ...CABLAB.workdir
import Compat.UTF8String
using Base.Dates
import NullableArrays.NullableArray
import NullableArrays.isnull
global const debugDAT=false
macro debug_print(e)
  debugDAT && return(:(println($e)))
  :()
end
#Clear Temp Folder when loading
#myid()==1 && isdir(joinpath(workdir[1],"tmp")) && rm(joinpath(workdir[1],"tmp"),recursive=true)

"""
Configuration object of a DAT process. This holds all necessary information to perform the calculations
It contains the following fields:

- `incubes::Vector{AbstractCubeData}` The input data cubes
- `outcube::AbstractCubeData` The output data cube
- `indims::Vector{Tuple}` Tuples of input axis types
- `outdims::Tuple` Tuple of output axis types
- `axlists::Vector{Vector{CubeAxis}}` Axes of the input data cubes
- `inAxes::Vector{Vector{CubeAxis}}`
- outAxes::Vector{CubeAxis}
- LoopAxes::Vector{CubeAxis}
- axlistOut::Vector{CubeAxis}
- ispar::Bool
- isMem::Vector{Bool}
- inCubesH
- outCubeH

"""
type DATConfig{N}
  NIN           :: Int
  incubes       :: Vector
  outcube       :: AbstractCubeData
  axlists       :: Vector #Of vectors
  inAxes        :: Vector #Of vectors
  broadcastAxes :: Vector #Of Vectors
  outAxes       :: Vector
  LoopAxes      :: Vector
  axlistOut     :: Vector
  ispar         :: Bool
  isMem         :: Vector{Bool}
  inCacheSizes  :: Vector #of vectors
  loopCacheSize :: Vector{Int}
  inCubesH
  outCubeH
  max_cache
  outfolder
  sfu
  inmissing     :: Tuple
  outmissing    :: Symbol
  no_ocean      :: Int
  inplace      :: Bool
  addargs
  kwargs
end
function DATConfig(incubes::Tuple,inAxes,outAxes,outtype,max_cache,outfolder,sfu,inmissing,outmissing,no_ocean,inplace,addargs,kwargs)
  DATConfig{length(incubes)}(length(incubes),AbstractCubeData[c for c in incubes],EmptyCube{outtype}(),Vector{CubeAxis}[],inAxes,
  Vector{Int}[],CubeAxis[a for a in outAxes],CubeAxis[],CubeAxis[],nprocs()>1,Bool[isa(x,AbstractCubeMem) for x in incubes],
  Vector{Int}[],Int[],[],[],max_cache,outfolder,sfu,inmissing,outmissing,no_ocean,inplace,addargs,kwargs)
end

"""
Object to pass to InnerLoop, this condenses the most important information about the calculation into a type so that
specific code can be generated by the @generated function
"""
immutable InnerObj{NIN,T1,T2,T3,MIN,MOUT,OC,R} end
function InnerObj(dc::DATConfig)
  T1=totuple(map(length,dc.inAxes))
  T2=length(dc.outAxes)
  T3=totuple(map(totuple,dc.broadcastAxes))
  MIN=dc.inmissing
  MOUT=dc.outmissing
  OC=dc.no_ocean
  R=dc.inplace
  InnerObj{dc.NIN,T1,T2,T3,MIN,MOUT,OC,R}()
end

immutable DATFunction
  indims
  outdims
  args
  outtype
  inmissing
  outmissing
  no_ocean::Int
  inplace::Bool
end
const regDict=Dict{UTF8String,DATFunction}()

getOuttype(outtype::Type{Any},cdata)=isa(cdata,AbstractCubeData) ? eltype(cdata) : eltype(cdata[1])
getOuttype(outtype,cdata)=outtype
getInAxes(indims::Tuple{Vararg{DataType}},cdata)=getInAxes((indims,),cdata)
getInAxes(indims::Tuple{Vararg{Tuple{Vararg{DataType}}}},cdata::AbstractCubeData)=getInAxes(indims,(cdata,))
function getInAxes(indims::Tuple{Vararg{Tuple{Vararg{DataType}}}},cdata::Tuple)
  inAxes=Vector{CubeAxis}[]
  for (dat,dim) in zip(cdata,indims)
    ii=collect(map(a->findAxis(a,axes(dat)),dim))
    if length(ii) > 0
      push!(inAxes,axes(dat)[ii])
    else
      push!(inAxes,CubeAxis[])
    end
  end
  inAxes
end
getOutAxes(outdims,cdata,pargs)=map(t->getOutAxes(cdata,t,pargs),outdims)
function getOutAxes(cdata::Tuple,t::DataType,pargs)
  for da in cdata
    ii = findAxis(t,axes(da))
    ii>0 && return axes(da)[ii]
  end
end
getOutAxes(cdata::Tuple,t::Function,pargs)=t(cdata,pargs)


mapCube(fu::Function,cdata::AbstractCubeData,addargs...;kwargs...)=mapCube(fu,(cdata,),addargs...;kwargs...)

function getReg(fuObj::DATFunction,name::Symbol,cdata)
  return getfield(fuObj,name)
end
function getReg(sfu,name::Symbol,cdata)
  if     name==:outtype    return Any
  elseif name==:inAxes     return ntuple(i->(),length(cdata))
  elseif name==:outAxes    return ()
  elseif name==:inmissing  return ntuple(i->:mask,length(cdata))
  elseif name==:outmissing return :mask
  elseif name==:no_ocean   return 0
  elseif name==:inplace    return true
  end
end

"""
    reduceCube(f::Function, cube, dim::Type{T<:CubeAxis};kwargs...)

Apply a reduction function `f` on slices of the cube `cube`. The dimension(s) are specified through `dim`, which is
either an Axis type or a tuple of axis types. Keyword arguments are passed to `mapCube` or, if not known to `f`.
It is assumed that `f` takes an array input and returns a single value.
"""
reduceCube{T<:CubeAxis}(f::Function,c::CABLAB.Cubes.AbstractCubeData,dim::Type{T};kwargs...)=reduceCube(f,c,dim;kwargs...)
function reduceCube(f::Function,c::CABLAB.Cubes.AbstractCubeData,dim::Tuple,no_ocean=any(i->isa(i,LonAxis) || isa(i,LatAxis),axes(c)) ? 0 : 1;kwargs...)
  axlist=axes(c)
  if any(i->isa(i,LatAxis),axlist)
    return mapCube(f,c,indims=dim,outdims=(),inmissing=(:nullable,),outmissing=(:nullable),inplace=false;kwargs...)
  else
    return mapCube(f,c,indims=dim,outdims=(),inmissing=(:nullable,),outmissing=(:nullable),inplace=false;kwargs...)
  end
end


"""
    mapCube(fun, cube)

Map a given function `fun` over slices of the data cube `cube`.
"""
function mapCube(fu::Function,
    cdata::Tuple,addargs...;
    max_cache=1e7,
    outfolder=joinpath(workdir[1],
    string(tempname()[2:end],fu)),
    sfu=split(string(fu),".")[end],
    fuObj=get(regDict,sfu,sfu),
    outtype=getReg(fuObj,:outtype,cdata),
    indims=getReg(fuObj,:indims,cdata),
    outdims=getReg(fuObj,:outdims,cdata),
    inmissing=getReg(fuObj,:inmissing,cdata),
    outmissing=getReg(fuObj,:outmissing,cdata),
    no_ocean=getReg(fuObj,:no_ocean,cdata),
    inplace=getReg(fuObj,:inplace,cdata),
    kwargs...)
  @debug_print "In map function"
  isdir(outfolder) || mkpath(outfolder)
  @debug_print "Generating DATConfig"
  dc=DATConfig(cdata,getInAxes(indims,cdata),getOutAxes(outdims,cdata,addargs),getOuttype(outtype,cdata),max_cache,outfolder,sfu,inmissing,outmissing,no_ocean,inplace,addargs,kwargs)
  analyseaddargs(fuObj,dc)
  @debug_print "Reordering Cubes"
  reOrderInCubes(dc)
  @debug_print "Analysing Axes"
  analyzeAxes(dc)
  @debug_print "Calculating Cache Sizes"
  getCacheSizes(dc)
  @debug_print "Generating Output Cube"
  generateOutCube(dc)
  @debug_print "Generating cube handles"
  getCubeHandles(dc)
  @debug_print "Running main Loop"
  runLoop(dc)

  return dc.outcube

end

function enterDebug(fu::Function,
    cdata::Tuple,addargs...;
    max_cache=1e7,
    outfolder=joinpath(workdir[1],
    string(tempname()[2:end],fu)),
    sfu=split(string(fu),".")[end],
    fuObj=get(regDict,sfu,sfu),
    outtype=getOuttype(fuObj,cdata),
    inAxes=getInAxes(fuObj,cdata),
    outAxes=getOutAxes(fuObj,cdata,addargs),
    inmissing=isa(fuObj,DATFunction) ? fuObj.inmissing : ntuple(i->:mask,length(cdata)),
    outmissing=isa(fuObj,DATFunction) ? fuObj.outmissing : :mask,
    no_ocean=isa(fuObj,DATFunction) ? fuObj.no_ocean : 0,
    inplace=isa(fuObj,DATFunction) ? fuObj.inplace : true)
    isdir(outfolder) || mkpath(outfolder)
    return DATConfig(cdata,inAxes,outAxes,outtype,max_cache,outfolder,sfu,inmissing,outmissing,no_ocean,inplace,addargs,kwargs),fuObj
end

function analyseaddargs(sfu::DATFunction,dc)
    dc.addargs=isa(sfu.args,Function) ? sfu.args(dc.incubes,dc.addargs) : dc.addargs
end
analyseaddargs(sfu::AbstractString,dc)=nothing

function mustReorder(cdata,inAxes)
  reorder=false
  axlist=axes(cdata)
  for (i,fi) in enumerate(inAxes)
    axlist[i]==fi || return true
  end
  return false
end

function reOrderInCubes(dc::DATConfig)
  cdata=dc.incubes
  inAxes=dc.inAxes
  for i in 1:length(cdata)
    if mustReorder(cdata[i],inAxes[i])
      perm=getFrontPerm(cdata[i],inAxes[i])
      cdata[i]=permutedims(cdata[i],perm)
    end
    push!(dc.axlists,axes(cdata[i]))
  end
end

function runLoop(dc::DATConfig)
  if dc.ispar
    allRanges=distributeLoopRanges(dc.outcube.block_size.I[(end-length(dc.LoopAxes)+1):end],map(length,dc.LoopAxes))
    pmap(r->CABLAB.DAT.innerLoop(Val{Symbol(Main.PMDATMODULE.dc.sfu)},CABLAB.CABLABTools.totuple(Main.PMDATMODULE.dc.inCubesH),
      Main.PMDATMODULE.dc.outCubeH[1],CABLAB.DAT.InnerObj(Main.PMDATMODULE.dc),r,Main.PMDATMODULE.dc.addargs,Main.PMDATMODULE.dc.kwargs),allRanges)
    isa(dc.outcube,TempCube) && @everywhereelsem CachedArrays.sync(dc.outCubeH[1])
  else
    innerLoop(Val{Symbol(dc.sfu)},totuple(dc.inCubesH),dc.outCubeH[1],InnerObj(dc),totuple(map(length,dc.LoopAxes)),dc.addargs,dc.kwargs)
    isa(dc.outCubeH[1],CachedArray) && CachedArrays.sync(dc.outCubeH[1])
  end
  dc.outcube
end

function generateOutCube(dc::DATConfig)
  T=eltype(dc.outcube)
  outsize=sizeof(T)*(length(dc.axlistOut)>0 ? prod(map(length,dc.axlistOut)) : 1)
  if outsize>dc.max_cache || dc.ispar
    dc.outcube=TempCube(dc.axlistOut,CartesianIndex(totuple([map(length,dc.outAxes);dc.loopCacheSize])),folder=dc.outfolder,T=T)
  else
    newsize=map(length,dc.axlistOut)
    dc.outcube = Cubes.CubeMem{T,length(newsize)}(dc.axlistOut, zeros(T,newsize...),zeros(UInt8,newsize...))
  end
end

dcg=nothing
function getCubeHandles(dc::DATConfig)
  if dc.ispar
    global dcg=dc
    try
      passobj(1, workers(), [:dcg],from_mod=CABLAB.DAT,to_mod=Main.PMDATMODULE)
    end
    @everywhereelsem begin
      dc=Main.PMDATMODULE.dcg
      tc=openTempCube(dc.outfolder)
      push!(dc.outCubeH,CachedArray(tc,1,tc.block_size,MaskedCacheBlock{eltype(tc),length(tc.block_size.I)}))
      for icube=1:dc.NIN
        if dc.isMem[icube]
          push!(dc.inCubesH,dc.incubes[icube])
        else
          push!(dc.inCubesH,CachedArray(dc.incubes[icube],1,CartesianIndex(totuple(dc.inCacheSizes[icube])),MaskedCacheBlock{eltype(dc.incubes[icube]),length(dc.axlists[icube])}))
        end
      end
    end
  else
    # For one-processor operations
    for icube=1:dc.NIN
      if dc.isMem[icube]
        push!(dc.inCubesH,dc.incubes[icube])
      else
        push!(dc.inCubesH,CachedArray(dc.incubes[icube],1,CartesianIndex(totuple(dc.inCacheSizes[icube])),MaskedCacheBlock{eltype(dc.incubes[icube]),length(dc.axlists[icube])}))
      end
    end
    if isa(dc.outcube,TempCube)
      push!(dc.outCubeH,CachedArray(dc.outcube,1,dc.outcube.block_size,MaskedCacheBlock{eltype(dc.outcube),length(dc.axlistOut)}))
    else
      push!(dc.outCubeH,dc.outcube)
    end
  end
end

function init_DATworkers()
  freshworkermodule()
end

function analyzeAxes(dc::DATConfig)
  #First check if one of the axes is a concrete type
  for icube=1:dc.NIN
    for a in dc.axlists[icube]
      in(a,dc.inAxes[icube]) || in(a,dc.LoopAxes) || push!(dc.LoopAxes,a)
    end
  end
  #Try to construct outdims
  outnotfound=find([!isdefined(dc.outAxes,ii) for ii in eachindex(dc.outAxes)])
  for ii in outnotfound
    dc.outAxes[ii]=dc.outdims[ii]()
  end
  length(dc.LoopAxes)==length(unique(map(typeof,dc.LoopAxes))) || error("Make sure that cube axes of different cubes match")
  dc.axlistOut=CubeAxis[dc.outAxes;dc.LoopAxes]
  for icube=1:dc.NIN
    push!(dc.broadcastAxes,Int[])
    for iLoopAx=1:length(dc.LoopAxes)
      !in(typeof(dc.LoopAxes[iLoopAx]),map(typeof,dc.axlists[icube])) && push!(dc.broadcastAxes[icube],iLoopAx)
    end
  end
  return dc
end

function getCacheSizes(dc::DATConfig)

  if all(dc.isMem)
    dc.inCacheSizes=[Int[] for i=1:dc.NIN]
    dc.loopCacheSize=Int[length(x) for x in dc.LoopAxes]
    return dc
  end
  inAxlengths      = [Int[length(dc.inAxes[i][j]) for j=1:length(dc.inAxes[i])] for i=1:length(dc.inAxes)]
  inblocksizes     = map((x,T)->prod(x)*sizeof(eltype(T)),inAxlengths,dc.incubes)
  inblocksize,imax = findmax(inblocksizes)
  outblocksize     = length(dc.outAxes)>0 ? sizeof(eltype(dc.outcube))*prod(map(length,dc.outAxes)) : 1
  loopCacheSize    = getLoopCacheSize(max(inblocksize,outblocksize),dc.LoopAxes,dc.max_cache)
  @debug_print "Choosing Cache Size of $loopCacheSize"
  for icube=1:dc.NIN
    if dc.isMem[icube]
      push!(dc.inCacheSizes,Int[])
    else
      push!(dc.inCacheSizes,map(length,dc.inAxes[icube]))
      for iLoopAx=1:length(dc.LoopAxes)
        in(typeof(dc.LoopAxes[iLoopAx]),map(typeof,dc.axlists[icube])) && push!(dc.inCacheSizes[icube],loopCacheSize[iLoopAx])
      end
    end
  end
  dc.loopCacheSize=loopCacheSize
  return dc
end

"Calculate optimal Cache size to DAT operation"
function getLoopCacheSize(preblocksize,LoopAxes,max_cache)
  totcachesize=max_cache

  incfac=totcachesize/preblocksize
  incfac<1 && error("Not enough memory, please increase availabale cache size")
  loopCacheSize = ones(Int,length(LoopAxes))
  for iLoopAx=1:length(LoopAxes)
    s=length(LoopAxes[iLoopAx])
    if s<incfac
      loopCacheSize[iLoopAx]=s
      incfac=incfac/s
      continue
    else
      ii=floor(Int,incfac)
      while ii>1 && rem(s,ii)!=0
        ii=ii-1
      end
      loopCacheSize[iLoopAx]=ii
      break
    end
  end
  return loopCacheSize
  j=1
  CacheInSize=Int[]
  for a in axlist
    if typeof(a) in indims
      push!(CacheInSize,length(a))
    else
      push!(CacheInSize,loopCacheSize[j])
      j=j+1
    end
  end
  @assert j==length(loopCacheSize)+1
  CacheOutSize = [map(length,outAxes);loopCacheSize]
  return CacheInSize, CacheOutSize
end

using Base.Cartesian
@generated function distributeLoopRanges{N}(block_size::NTuple{N,Int},loopR::Vector)
    quote
        @assert length(loopR)==N
        nsplit=Int[div(l,b) for (l,b) in zip(loopR,block_size)]
        baseR=UnitRange{Int}[1:b for b in block_size]
        a=Array(NTuple{$N,UnitRange{Int}},nsplit...)
        @nloops $N i a begin
            rr=@ntuple $N d->baseR[d]+(i_d-1)*block_size[d]
            @nref($N,a,i)=rr
        end
        a=reshape(a,length(a))
    end
end

using Base.Cartesian
@generated function innerLoop{fT,T1,T2,T3,T4,NIN,M1,M2,OC,R}(::Type{Val{fT}},xin,xout,::InnerObj{NIN,T1,T2,T4,M1,M2,OC,R},loopRanges::T3,addargs,kwargs)
  NinCol      = T1
  NoutCol     = T2
  broadcastvars = T4
  inmissing     = M1
  outmissing    = M2
  Nloopvars   = length(T3.parameters)
  loopRangesE = Expr(:block)
  subIn=[NinCol[i] > 0 ? Expr(:call,:(getSubRange2),:(xin[$i]),fill(:(:),NinCol[i])...) : Expr(:call,:(CABLAB.CubeAPI.CachedArrays.getSingVal),:(xin[$i])) for i=1:NIN]
  subOut=Expr(:call,:(getSubRange2),:xout,fill(:(:),NoutCol)...)
  printex=Expr(:call,:println,:outstream)
  for i=Nloopvars:-1:1
    isym=Symbol("i_$(i)")
    push!(printex.args,string(isym),"=",isym," ")
  end
  for i=1:Nloopvars
    isym=Symbol("i_$(i)")
    for j=1:NIN
      in(i,broadcastvars[j]) || push!(subIn[j].args,isym)
    end
    push!(subOut.args,isym)
    if T3.parameters[i]==UnitRange{Int}
      unshift!(loopRangesE.args,:($isym=loopRanges[$i]))
    elseif T3.parameters[i]==Int
      unshift!(loopRangesE.args,:($isym=1:loopRanges[$i]))
    else
      error("Wrong Range argument")
    end
  end
  push!(subOut.args,Expr(:kw,:write,true))
  loopBody=quote
    aout,mout=$subOut
  end
  callargs=Any[:(Main.$(fT)),Expr(:parameters,Expr(:...,:kwargs))]
  if R
    push!(callargs,:aout)
    outmissing==:mask && push!(callargs,:mout)
  end
  if outmissing==:nullable
    push!(loopBody.args,:(aout=toNullableArray(aout,mout)))
  end
  for (i,s) in enumerate(subIn)
    ains=Symbol("ain_$i");mins=Symbol("min_$i")
    push!(loopBody.args,:(($(ains),$(mins))=$s))
    push!(callargs,ains)
    if inmissing[i]==:mask
      push!(callargs,mins)
    elseif inmissing[i]==:nan
      push!(loopBody.args,:(fillNaNs($(ains),$(mins))))
    elseif inmissing[i]==:nullable
      push!(loopBody.args,:($(ains)=toNullableArray($(ains),$(mins))))
    end
  end
  if OC>0
    ocex=quote
      if ($(Symbol(string("min_",OC)))[1] & OCEAN) == OCEAN
          mout[:]=OCEAN
          continue
      end
    end
    push!(loopBody.args,ocex)
  end
  push!(callargs,Expr(:...,:addargs))
  if R
    push!(loopBody.args,Expr(:call,callargs...))
  else
    if outmissing==:mask
      push!(loopBody.args,quote
        ao,mo=$(Expr(:call,callargs...))
        aout[1]=ao
        mout[1]=mo
      end)
    else
      push!(loopBody.args,:(aout[1]=$(Expr(:call,callargs...))))
    end
  end
  if outmissing==:nan
    push!(loopBody.args, :(fillNanMask(aout,mout)))
  elseif outmissing==:nullable
    push!(loopBody.args,:(fillNullableArrayMask(aout,mout)))
  end
  loopEx = length(loopRangesE.args)==0 ? loopBody : Expr(:for,loopRangesE,loopBody)
  if debugDAT
    b=IOBuffer()
    show(b,loopEx)
    s=takebuf_string(b)
    loopEx=quote
      println($s)
      $loopEx
    end
  end
  return loopEx
end

"This function sets the values of x to NaN if the mask is missing"
function fillNaNs(x::AbstractArray,m::AbstractArray{UInt8})
  nmiss=0
  @inbounds for i in eachindex(x)
    if (m[i] & 0x01)==0x01
      x[i]=NaN
      nmiss+=1
    end
  end
  return nmiss==length(x) ? true : false
end
fillNaNs(x,::Void)=nothing
"Sets the mask to missing if values are NaN"
function fillNanMask(x,m)
  for i in eachindex(x)
    m[i]=isnan(x[i]) ? 0x01 : 0x00
  end
end
fillNanMask(m)=m[:]=0x01
#"Converts data and Mask to a NullableArray"
toNullableArray(x,m)=NullableArray(x,reinterpret(Bool,m))
fillNullableArrayMask(x,m)=for i in eachindex(x.data) m[i]=isnull(x[i]) ? 0x01 : 0x00 end

"""
    registerDATFunction(f, dimsin, [dimsout, [addargs]]; inmissing=(:mask,...), outmissing=:mask, no_ocean=0)

Registers a function so that it can be applied to the whole data cube through mapCube.

  - `f` the function to register
  - `dimsin` a tuple containing the Axes Types that the function is supposed to work on. If multiple input cubes are needed, then a tuple of tuples must be provided
  - `dimsout` a tuple of output Axes types. If omitted, it is assumed that the output is a single value. Can also be a function with the signature (cube,pargs)-> ... which returns the output Axis. This is useful if the output axis can only be constructed based on runtime input.
  - `addargs` an optional function with the signature (cube,pargs)-> ... , to calculate function arguments that are passed to f which are only known when the function is called. Here `cube` is a tuple of input cubes provided when `mapCube` is called and `pargs` is a list of trailing arguments passed to `mapCube`. For example `(cube,pargs)->(length(getAxis(cube[1],"TimeAxis")),pargs[1])` would pass the length of the time axis and the first trailing argument of the mapCube call to each invocation of `f`
  - `inmissing` tuple of symbols, determines how to deal with missing data for each input cube. `:mask` means that masks are explicitly passed to the function call, `:nan` replaces all missing data with NaNs, and `:nullable` passes a NullableArray to `f`
  - `outmissing` symbol, determines how missing values is the output are interpreted. Same values as for `inmissing are allowed`
  - `no_ocean` integer, if set to a value > 0, omit function calls that would act on grid cells where the first value in the mask is set to `OCEAN`.
  - `inplace::Bool` defaults to true. If `f` returns a single value, instead of writing into an output array, one can set `inplace=false`.

"""
function registerDATFunction(f,dimsin::Tuple{Vararg{Tuple{Vararg{DataType}}}},dimsout::Tuple,addargs;outtype=Any,inmissing=ntuple(i->:mask,length(dimsin)),outmissing=:mask,no_ocean=0,inplace=true)
    fname=string(split(string(f),".")[end])
    regDict[fname]=DATFunction(dimsin,dimsout,addargs,outtype,inmissing,outmissing,no_ocean,inplace)
end
registerDATFunction(f, ::Tuple{}, dimsout::Tuple, addargs)=registerDATFunction(f,((),),dimsout,addargs;kwargs...)
registerDATFunction(f,dimsin::Tuple{Vararg{DataType}},dimsout::Tuple,addargs;kwargs...)=registerDATFunction(f,(dimsin,),dimsout,addargs;kwargs...)
registerDATFunction(f,dimsin,dimsout;kwargs...)=registerDATFunction(f,dimsin,dimsout,();kwargs...)
registerDATFunction(f,dimsin;kwargs...)=registerDATFunction(f,dimsin,();kwargs...)

"Find a certain axis type in a vector of Cube axes and returns the index"
function findAxis{T<:CubeAxis}(a::Type{T},v)
    for i=1:length(v)
        isa(v[i],a) && return i
    end
    return 0
end

function findAxis(matchstr::AbstractString,axlist)
    ism=map(i->startswith(lowercase(split(string(typeof(i)),".")[end]),lowercase(matchstr)),axlist)
  sism=sum(ism)
  sism==0 && error("No axis found matching string $matchstr")
  sism>1 && error("Multiple axes found matching string $matchstr")
  i=findfirst(ism)
end


function getAxis{T<:CubeAxis}(a::Type{T},v)
  for i=1:length(v)
      isa(v[i],a) && return a
  end
  return 0
end

function getAxis{T<:CubeAxis}(a::Type{T},cube::AbstractCubeData,)
  for ax in axes(cube)
      isa(ax,a) && return ax
  end
  error("Axis $a not found in $(axes(cube))")
end


"Calculate an axis permutation that brings the wanted dimensions to the front"
function getFrontPerm{T}(dc::AbstractCubeData{T},dims)
  ax=axes(dc)
  N=length(ax)
  perm=Int[i for i=1:length(ax)];
  iold=Int[]
  for i=1:length(dims) push!(iold,findin(ax,[dims[i];])[1]) end
  iold2=sort(iold,rev=true)
  for i=1:length(iold) splice!(perm,iold2[i]) end
  perm=Int[iold;perm]
  return ntuple(i->perm[i],N)
end

end
