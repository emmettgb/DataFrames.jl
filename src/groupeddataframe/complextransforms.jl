_nrow(df::AbstractDataFrame) = nrow(df)
_nrow(x::NamedTuple{<:Any, <:Tuple{Vararg{AbstractVector}}}) =
    isempty(x) ? 0 : length(x[1])
_ncol(df::AbstractDataFrame) = ncol(df)
_ncol(x::Union{NamedTuple, DataFrameRow}) = length(x)

function _combine_multicol(firstres, fun::Base.Callable, gd::GroupedDataFrame,
                           incols::Union{Nothing, AbstractVector, Tuple, NamedTuple})
    firstmulticol = firstres isa MULTI_COLS_TYPE
    if !(firstres isa Union{AbstractVecOrMat, AbstractDataFrame,
                            NamedTuple{<:Any, <:Tuple{Vararg{AbstractVector}}}})
        idx_agg = Vector{Int}(undef, length(gd))
        fillfirst!(nothing, idx_agg, 1:length(gd.groups), gd)
    else
        idx_agg = nothing
    end
    return _combine_with_first(wrap(firstres), fun, gd, incols,
                               Val(firstmulticol), idx_agg)
end

function _combine_with_first(first::Union{NamedTuple, DataFrameRow, AbstractDataFrame},
                             f::Base.Callable, gd::GroupedDataFrame,
                             incols::Union{Nothing, AbstractVector, Tuple, NamedTuple},
                             firstmulticol::Val, idx_agg::Union{Nothing, AbstractVector{<:Integer}})
    extrude = false

    if first isa AbstractDataFrame
        n = 0
        eltys = eltype.(eachcol(first))
    elseif first isa NamedTuple{<:Any, <:Tuple{Vararg{AbstractVector}}}
        n = 0
        eltys = map(eltype, first)
    elseif first isa DataFrameRow
        n = length(gd)
        eltys = [eltype(parent(first)[!, i]) for i in parentcols(index(first))]
    elseif firstmulticol == Val(false) && first[1] isa Union{AbstractArray{<:Any, 0}, Ref}
        extrude = true
        first = wrap_row(first[1], firstmulticol)
        n = length(gd)
        eltys = (typeof(first[1]),)
    else # other NamedTuple giving a single row
        n = length(gd)
        eltys = map(typeof, first)
        if any(x -> x <: AbstractVector, eltys)
            throw(ArgumentError("mixing single values and vectors in a named tuple is not allowed"))
        end
    end
    idx = isnothing(idx_agg) ? Vector{Int}(undef, n) : idx_agg
    local initialcols
    let eltys=eltys, n=n # Workaround for julia#15276
        initialcols = ntuple(i -> Tables.allocatecolumn(eltys[i], n), _ncol(first))
    end
    targetcolnames = tuple(propertynames(first)...)
    if !extrude && first isa Union{AbstractDataFrame,
                                   NamedTuple{<:Any, <:Tuple{Vararg{AbstractVector}}}}
        outcols, finalcolnames = _combine_tables_with_first!(first, initialcols, idx, 1, 1,
                                                             f, gd, incols, targetcolnames,
                                                             firstmulticol)
    else
        outcols, finalcolnames = _combine_rows_with_first!(first, initialcols,
                                                           f, gd, incols, targetcolnames,
                                                           firstmulticol)
    end
    return idx, outcols, collect(Symbol, finalcolnames)
end

function fill_row!(row, outcols::NTuple{N, AbstractVector},
                   i::Integer, colstart::Integer,
                   colnames::NTuple{N, Symbol}) where N
    if _ncol(row) != N
        throw(ArgumentError("return value must have the same number of columns " *
                            "for all groups (got $N and $(length(row)))"))
    end
    @inbounds for j in colstart:length(outcols)
        col = outcols[j]
        cn = colnames[j]
        local val
        try
            val = row[cn]
        catch
            throw(ArgumentError("return value must have the same column names " *
                                "for all groups (got $colnames and $(propertynames(row)))"))
        end
        S = typeof(val)
        T = eltype(col)
        if S <: T || promote_type(S, T) <: T
            col[i] = val
        else
            return j
        end
    end
    return nothing
end

function _combine_rows_with_first_task!(tid::Integer,
                                        idx::AbstractVector{<:Integer},
                                        outcols::NTuple{<:Any, AbstractVector},
                                        outcolsref::Ref{NTuple{<:Any, AbstractVector}},
                                        type_widened::AbstractVector{Bool},
                                        widen_type_lock::ReentrantLock,
                                        i::Integer,
                                        f::Base.Callable,
                                        gd::GroupedDataFrame,
                                        starts::AbstractVector{<:Integer},
                                        ends::AbstractVector{<:Integer},
                                        incols::Union{Nothing, AbstractVector,
                                                      Tuple, NamedTuple},
                                        colnames::NTuple{<:Any, Symbol},
                                        firstmulticol::Val)
    j = nothing
    gdidx = gd.idx
    local newoutcols
    for i in idx
        row = wrap_row(do_call(f, gdidx, starts, ends, gd, incols, i), firstmulticol)
        j = fill_row!(row, outcols, i, 1, colnames)
        if j !== nothing # Need to widen column
            # If another thread is already widening outcols, wait until it's done
            lock(widen_type_lock)
            try
                newoutcols = outcolsref[]
                # Workaround for julia#15276
                newoutcols = let i=i, j=j, newoutcols=newoutcols, row=row, idx=idx
                    ntuple(length(newoutcols)) do k
                        S = typeof(row[k])
                        T = eltype(newoutcols[k])
                        U = promote_type(S, T)
                        if S <: T || U <: T
                            newoutcols[k]
                        else
                            Tables.allocatecolumn(U, length(newoutcols[k]))
                        end
                    end
                end
                j = fill_row!(row, newoutcols, i, j, colnames)
                @assert j === nothing # eltype is guaranteed to match
                for k in 1:length(outcols)
                    if outcols[k] !== newoutcols[k]
                        copyto!(newoutcols[k], idx[1],
                                outcols[k], idx[1], i - idx[1] + 1)
                    end
                end
                outcolsref[] = newoutcols
                type_widened .= true
                type_widened[tid] = false
            finally
                unlock(widen_type_lock)
            end
            return _combine_rows_with_first_task!(tid, idx, newoutcols, outcolsref,
                                                  type_widened, widen_type_lock,
                                                  i+1, f, gd, starts, ends,
                                                  incols, colnames, firstmulticol)
        end
        # If other thread widened columns, copy already processed data to new vectors
        # This doesn't have to happen immediately (hence type_widened isn't atomic),
        # but the more we wait the more data will have to be copied
        if type_widened[tid]
            lock(widen_type_lock) do
                type_widened[tid] = false
                newoutcols = outcolsref[]
                for k in 1:length(outcols)
                    if outcols[k] !== newoutcols[k]
                        copyto!(newoutcols[k], idx[1],
                                outcols[k], idx[1], i - idx[1] + 1)
                    end
                end
            end
            return _combine_rows_with_first_task!(tid, idx, newoutcols, outcolsref,
                                                  type_widened, widen_type_lock,
                                                  i+1, f, gd, starts, ends,
                                                  incols, colnames, firstmulticol)
        end
    end
    return outcols
end

function _combine_rows_with_first!(first::Union{NamedTuple, DataFrameRow},
                                   outcols::NTuple{N, AbstractVector},
                                   f::Base.Callable, gd::GroupedDataFrame,
                                   incols::Union{Nothing, AbstractVector, Tuple, NamedTuple},
                                   colnames::NTuple{N, Symbol},
                                   firstmulticol::Val) where N
    len = length(gd)
    gdidx = gd.idx
    starts = gd.starts
    ends = gd.ends

    # handle empty GroupedDataFrame
    len == 0 && return outcols, colnames

    # Handle groups other than the first one (which is handled below)
    # Create up to one task per thread
    # This has lower overhead than creating one task per group,
    # but is optimal only if operations take roughly the same time for all groups
    basesize = max(1, (len - 1) ÷ Threads.nthreads())
    partitions = collect(_partition(2:len, basesize))
    widen_type_lock = ReentrantLock()
    outcolsref = Ref{NTuple{<:Any, AbstractVector}}(outcols)
    type_widened = fill(false, length(partitions))
    tasks = similar(partitions, Task)
    for tid in 1:length(partitions)
        idx = partitions[tid]
        tasks[tid] =
            @spawn _combine_rows_with_first_task!(tid, idx, outcols, outcolsref,
                                                  type_widened, widen_type_lock,
                                                  1, f, gd, starts, ends, incols, colnames,
                                                  firstmulticol)
    end

    # Workaround JuliaLang/julia#38931:
    # we want to preserve the exception type thrown in user code,
    # and print the backtrace corresponding to it
    for t in tasks
        try
            wait(t)
        catch e
            throw(t.exception)
        end
    end

    # Copy data for any tasks that finished before others widened columns
    outcols = outcolsref[]
    for tid in 1:length(partitions)
        if type_widened[tid]
            idx = partitions[tid]
            oldoutcols = fetch(tasks[tid])
            for k in 1:length(outcols)
                if oldoutcols[k] !== outcols[k]
                    copyto!(outcols[k], idx[1], oldoutcols[k], idx[1],
                            idx[end] - idx[1] + 1)
                end
            end
        end
    end

    # Handle first group
    # This is done at the end to write directly to the final outcols
    j1 = fill_row!(first, outcols, 1, 1, colnames)
    @assert j1 === nothing # eltype is guaranteed to match

    return outcols, colnames
end

# This needs to be in a separate function
# to work around a crash due to JuliaLang/julia#29430
if VERSION >= v"1.1.0-DEV.723"
    @inline function do_append!(do_it, col, vals)
        do_it && append!(col, vals)
        return do_it
    end
else
    @noinline function do_append!(do_it, col, vals)
        do_it && append!(col, vals)
        return do_it
    end
end

function append_rows!(rows, outcols::NTuple{N, AbstractVector},
                      colstart::Integer, colnames::NTuple{N, Symbol}) where N
    if !isa(rows, Union{AbstractDataFrame, NamedTuple{<:Any, <:Tuple{Vararg{AbstractVector}}}})
        throw(ArgumentError(ERROR_ROW_COUNT))
    elseif _ncol(rows) != N
        throw(ArgumentError("return value must have the same number of columns " *
                            "for all groups (got $N and $(_ncol(rows)))"))
    end
    @inbounds for j in colstart:length(outcols)
        col = outcols[j]
        cn = colnames[j]
        local vals
        try
            vals = getproperty(rows, cn)
        catch
            throw(ArgumentError("return value must have the same column names " *
                                "for all groups (got $colnames and $(propertynames(rows)))"))
        end
        S = eltype(vals)
        T = eltype(col)
        if !do_append!(S <: T || promote_type(S, T) <: T, col, vals)
            return j
        end
    end
    return nothing
end

function _combine_tables_with_first!(first::Union{AbstractDataFrame,
                                     NamedTuple{<:Any, <:Tuple{Vararg{AbstractVector}}}},
                                     outcols::NTuple{N, AbstractVector},
                                     idx::Vector{Int}, rowstart::Integer, colstart::Integer,
                                     f::Base.Callable, gd::GroupedDataFrame,
                                     incols::Union{Nothing, AbstractVector, Tuple, NamedTuple},
                                     colnames::NTuple{N, Symbol},
                                     firstmulticol::Val) where N
    len = length(gd)
    gdidx = gd.idx
    starts = gd.starts
    ends = gd.ends
    # Handle first group

    @assert _ncol(first) == N
    if !isempty(colnames) && length(gd) > 0
        j = append_rows!(first, outcols, colstart, colnames)
        @assert j === nothing # eltype is guaranteed to match
        append!(idx, Iterators.repeated(gdidx[starts[rowstart]], _nrow(first)))
    end
    # Handle remaining groups
    @inbounds for i in rowstart+1:len
        rows = wrap_table(do_call(f, gdidx, starts, ends, gd, incols, i), firstmulticol)
        _ncol(rows) == 0 && continue
        if isempty(colnames)
            newcolnames = tuple(propertynames(rows)...)
            if rows isa AbstractDataFrame
                eltys = eltype.(eachcol(rows))
            else
                eltys = map(eltype, rows)
            end
            initialcols = ntuple(i -> Tables.allocatecolumn(eltys[i], 0), _ncol(rows))
            return _combine_tables_with_first!(rows, initialcols, idx, i, 1,
                                               f, gd, incols, newcolnames, firstmulticol)
        end
        j = append_rows!(rows, outcols, 1, colnames)
        if j !== nothing # Need to widen column type
            local newcols
            let i = i, j = j, outcols=outcols, rows=rows # Workaround for julia#15276
                newcols = ntuple(length(outcols)) do k
                    S = eltype(rows isa AbstractDataFrame ? rows[!, k] : rows[k])
                    T = eltype(outcols[k])
                    U = promote_type(S, T)
                    if S <: T || U <: T
                        outcols[k]
                    else
                        copyto!(Tables.allocatecolumn(U, length(outcols[k])), outcols[k])
                    end
                end
            end
            return _combine_tables_with_first!(rows, newcols, idx, i, j,
                                               f, gd, incols, colnames, firstmulticol)
        end
        append!(idx, Iterators.repeated(gdidx[starts[i]], _nrow(rows)))
    end
    return outcols, colnames
end
