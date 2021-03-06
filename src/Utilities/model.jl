## Storage of constraints
#
# All `F`-in-`S` constraints are stored in a vector of `ConstraintEntry{F, S}`.
# The index in this vector of a constraint of index
# `ci::MOI.ConstraintIndex{F, S}` is given by `model.constrmap[ci.value]`. The
# advantage of this representation is that it does not require any dictionary
# hence it never needs to compute a hash.
#
# It may seem redundant to store the constraint index `ci` as well as the
# function and sets in the tuple but it is used to efficiently implement the
# getter for `MOI.ListOfConstraintIndices{F, S}`. It is also used to implement
# `MOI.delete`. Indeed, when a constraint is deleted, it is removed from the
# vector hence the index in the vector of all the functions that were stored
# after must be decreased by one. As the constraint index is stored in the
# vector, it readily gives the entries of `model.constrmap` that need to be
# updated.
const ConstraintEntry{F, S} = Tuple{CI{F, S}, F, S}

const EMPTYSTRING = ""

# Implementation of MOI for vector of constraint
function _add_constraint(constrs::Vector{ConstraintEntry{F, S}}, ci::CI, f::F,
                         s::S) where {F, S}
    push!(constrs, (ci, f, s))
    length(constrs)
end

function _delete(constrs::Vector, ci::CI, i::Int)
    deleteat!(constrs, i)
    @view constrs[i:end] # will need to shift it in constrmap
end

_getindex(ci::CI, f::MOI.AbstractFunction, s::MOI.AbstractSet) = ci
function _getindex(constrs::Vector, ci::CI, i::Int)
    _getindex(constrs[i]...)
end

_getfun(ci::CI, f::MOI.AbstractFunction, s::MOI.AbstractSet) = f
function _getfunction(constrs::Vector, ci::CI, i::Int)
    @assert ci.value == constrs[i][1].value
    _getfun(constrs[i]...)
end

_gets(ci::CI, f::MOI.AbstractFunction, s::MOI.AbstractSet) = s
function _getset(constrs::Vector, ci::CI, i::Int)
    @assert ci.value == constrs[i][1].value
    _gets(constrs[i]...)
end

_modifyconstr(ci::CI{F, S}, f::F, s::S, change::F) where {F, S} = (ci, change, s)
_modifyconstr(ci::CI{F, S}, f::F, s::S, change::S) where {F, S} = (ci, f, change)
_modifyconstr(ci::CI{F, S}, f::F, s::S, change::MOI.AbstractFunctionModification) where {F, S} = (ci, modifyfunction(f, change), s)
function _modify(constrs::Vector{ConstraintEntry{F, S}}, ci::CI{F}, i::Int,
                 change) where {F, S}
    constrs[i] = _modifyconstr(constrs[i]..., change)
end

function _getnoc(constrs::Vector{ConstraintEntry{F, S}},
                 ::MOI.NumberOfConstraints{F, S}) where {F, S}
    return length(constrs)
end
# Might be called when calling NumberOfConstraint with different coefficient type than the one supported
_getnoc(::Vector, ::MOI.NumberOfConstraints) = 0

function _getloc(constrs::Vector{ConstraintEntry{F, S}})::Vector{Tuple{DataType, DataType}} where {F, S}
    isempty(constrs) ? [] : [(F, S)]
end

function _getlocr(constrs::Vector{ConstraintEntry{F, S}},
                  ::MOI.ListOfConstraintIndices{F, S}) where {F, S}
    return map(constr -> constr[1], constrs)
end
function _getlocr(constrs::Vector{<:ConstraintEntry},
                  ::MOI.ListOfConstraintIndices{F, S}) where {F, S}
    return CI{F, S}[]
end

# Implementation of MOI for AbstractModel
abstract type AbstractModel{T} <: MOI.ModelLike end

getconstrloc(model::AbstractModel, ci::CI) = model.constrmap[ci.value]

# Variables
function MOI.get(model::AbstractModel, ::MOI.NumberOfVariables)
    if model.variable_indices === nothing
        model.num_variables_created
    else
        length(model.variable_indices)
    end
end
function MOI.add_variable(model::AbstractModel)
    vi = VI(model.num_variables_created += 1)
    if model.variable_indices !== nothing
        push!(model.variable_indices, vi)
    end
    return vi
end
function MOI.add_variables(model::AbstractModel, n::Integer)
    [MOI.add_variable(model) for i in 1:n]
end

"""
    removevariable(f::MOI.AbstractFunction, s::MOI.AbstractSet, vi::MOI.VariableIndex)

Return a tuple `(g, t)` representing the constraint `f`-in-`s` with the
variable `vi` removed. That is, the terms containing the variable `vi` in the
function `f` are removed and the dimension of the set `s` is updated if
needed (e.g. when `f` is a `VectorOfVariables` with `vi` being one of the
variables).
"""
removevariable(f, s, vi::VI) = removevariable(f, vi), s
function removevariable(f::MOI.VectorOfVariables, s, vi::VI)
    g = removevariable(f, vi)
    if length(g.variables) != length(f.variables)
        t = updatedimension(s, length(g.variables))
    else
        t = s
    end
    return g, t
end
function _removevar!(constrs::Vector, vi::VI)
    for i in eachindex(constrs)
        ci, f, s = constrs[i]
        constrs[i] = (ci, removevariable(f, s, vi)...)
    end
    return []
end
function _removevar!(constrs::Vector{<:ConstraintEntry{MOI.SingleVariable}},
                     vi::VI)
    # If a variable is removed, the SingleVariable constraints using this variable
    # need to be removed too
    rm = []
    for (ci, f, s) in constrs
        if f.variable == vi
            push!(rm, ci)
        end
    end
    rm
end
function MOI.delete(model::AbstractModel, vi::VI)
    if !MOI.is_valid(model, vi)
        throw(MOI.InvalidIndex(vi))
    end
    model.objective = removevariable(model.objective, vi)
    rm = broadcastvcat(constrs -> _removevar!(constrs, vi), model)
    for ci in rm
        MOI.delete(model, ci)
    end
    if model.variable_indices === nothing
        model.variable_indices = Set(MOI.get(model,
                                             MOI.ListOfVariableIndices()))
    end
    delete!(model.variable_indices, vi)
    model.name_to_var = nothing
    if haskey(model.var_to_name, vi)
        delete!(model.var_to_name, vi)
    end
end

function MOI.is_valid(model::AbstractModel, ci::CI{F, S}) where {F, S}
    if ci.value > length(model.constrmap)
        false
    else
        loc = getconstrloc(model, ci)
        if iszero(loc) # This means that it has been deleted
            false
        elseif loc > MOI.get(model, MOI.NumberOfConstraints{F, S}())
            false
        else
            ci == _getindex(model, ci, getconstrloc(model, ci))
        end
    end
end
function MOI.is_valid(model::AbstractModel, vi::VI)
    if model.variable_indices === nothing
        return 1 ≤ vi.value ≤ model.num_variables_created
    else
        return in(vi, model.variable_indices)
    end
end

function MOI.get(model::AbstractModel, ::MOI.ListOfVariableIndices)
    if model.variable_indices === nothing
        return VI.(1:model.num_variables_created)
    else
        vis = collect(model.variable_indices)
        sort!(vis, by=vi->vi.value) # It needs to be sorted by order of creation
        return vis
    end
end

# Names
MOI.supports(::AbstractModel, ::MOI.Name) = true
function MOI.set(model::AbstractModel, ::MOI.Name, name::String)
    model.name = name
end
MOI.get(model::AbstractModel, ::MOI.Name) = model.name

MOI.supports(::AbstractModel, ::MOI.VariableName, vi::Type{VI}) = true
function MOI.set(model::AbstractModel, ::MOI.VariableName, vi::VI, name::String)
    model.var_to_name[vi] = name
    model.name_to_var = nothing # Invalidate the name map.
end
MOI.get(model::AbstractModel, ::MOI.VariableName, vi::VI) = get(model.var_to_name, vi, EMPTYSTRING)

function MOI.get(model::AbstractModel, ::Type{VI}, name::String)
    if model.name_to_var === nothing
        # Rebuild the map.
        model.name_to_var = Dict{String, VI}()
        for (var, var_name) in model.var_to_name
            if haskey(model.name_to_var, var_name)
                # -1 is a special value that means this string does not map to
                # a unique variable name.
                model.name_to_var[var_name] = VI(-1)
            else
                model.name_to_var[var_name] = var
            end
        end
    end
    result = get(model.name_to_var, name, nothing)
    if result == VI(-1)
        error("Multiple variables have the name $name.")
    else
        return result
    end
end

function MOI.get(model::AbstractModel, ::MOI.ListOfVariableAttributesSet)::Vector{MOI.AbstractVariableAttribute}
    isempty(model.var_to_name) ? [] : [MOI.VariableName()]
end

MOI.supports(model::AbstractModel, ::MOI.ConstraintName, ::Type{<:CI}) = true
function MOI.set(model::AbstractModel, ::MOI.ConstraintName, ci::CI, name::String)
    model.con_to_name[ci] = name
    model.name_to_con = nothing # Invalidate the name map.
end
MOI.get(model::AbstractModel, ::MOI.ConstraintName, ci::CI) = get(model.con_to_name, ci, EMPTYSTRING)

"""
    build_name_to_con_map(con_to_name::Dict{MOI.ConstraintIndex, String})

Create and return a reverse map from name to constraint index, given a map from
constraint index to name. The special value
`MOI.ConstraintIndex{Nothing, Nothing}(-1)` is used to indicate that multiple
constraints have the same name.
"""
function build_name_to_con_map(con_to_name::Dict{CI, String})
    name_to_con = Dict{String, CI}()
    for (con, con_name) in con_to_name
        if haskey(name_to_con, con_name)
            name_to_con[con_name] = CI{Nothing, Nothing}(-1)
        else
            name_to_con[con_name] = con
        end
    end
    return name_to_con
end


function MOI.get(model::AbstractModel, ConType::Type{<:CI}, name::String)
    if model.name_to_con === nothing
        # Rebuild the map.
        model.name_to_con = build_name_to_con_map(model.con_to_name)
    end
    ci = get(model.name_to_con, name, nothing)
    if ci == CI{Nothing, Nothing}(-1)
        error("Multiple constraints have the name $name.")
    elseif ci isa ConType
        return ci
    else
        return nothing
    end
end

function MOI.get(model::AbstractModel, ::MOI.ListOfConstraintAttributesSet)::Vector{MOI.AbstractConstraintAttribute}
    isempty(model.con_to_name) ? [] : [MOI.ConstraintName()]
end

# Objective
MOI.get(model::AbstractModel, ::MOI.ObjectiveSense) = model.sense
MOI.supports(model::AbstractModel, ::MOI.ObjectiveSense) = true
function MOI.set(model::AbstractModel, ::MOI.ObjectiveSense, sense::MOI.OptimizationSense)
    model.senseset = true
    model.sense = sense
end
function MOI.get(model::AbstractModel, ::MOI.ObjectiveFunctionType)
    return MOI.typeof(model.objective)
end
function MOI.get(model::AbstractModel, ::MOI.ObjectiveFunction{T})::T where T
    return model.objective
end
MOI.supports(model::AbstractModel, ::MOI.ObjectiveFunction) = true
function MOI.set(model::AbstractModel, ::MOI.ObjectiveFunction, f::MOI.AbstractFunction)
    model.objectiveset = true
    # f needs to be copied, see #2
    model.objective = copy(f)
end

function MOI.modify(model::AbstractModel, obj::MOI.ObjectiveFunction, change::MOI.AbstractFunctionModification)
    model.objective = modifyfunction(model.objective, change)
end

MOI.get(::AbstractModel, ::MOI.ListOfOptimizerAttributesSet) = MOI.AbstractOptimizerAttribute[]
function MOI.get(model::AbstractModel, ::MOI.ListOfModelAttributesSet)::Vector{MOI.AbstractModelAttribute}
    listattr = MOI.AbstractModelAttribute[]
    if model.senseset
        push!(listattr, MOI.ObjectiveSense())
    end
    if model.objectiveset
        push!(listattr, MOI.ObjectiveFunction{typeof(model.objective)}())
    end
    if !isempty(model.name)
        push!(listattr, MOI.Name())
    end
    listattr
end

# Constraints
function MOI.add_constraint(model::AbstractModel, f::F, s::S) where {F<:MOI.AbstractFunction, S<:MOI.AbstractSet}
    if MOI.supports_constraint(model, F, S)
        # We give the index value `nextconstraintid + 1` to the new constraint.
        # As the same counter is used for all pairs of F-in-S constraints,
        # the index value is unique across all constraint types as mentioned in
        # `@model`'s doc.
        ci = CI{F, S}(model.nextconstraintid += 1)
        # f needs to be copied, see #2
        push!(model.constrmap, _add_constraint(model, ci, copy(f), copy(s)))
        return ci
    else
        throw(MOI.UnsupportedConstraint{F, S}())
    end
end

function MOI.delete(model::AbstractModel, ci::CI)
    if !MOI.is_valid(model, ci)
        throw(MOI.InvalidIndex(ci))
    end
    for (ci_next, _, _) in _delete(model, ci, getconstrloc(model, ci))
        model.constrmap[ci_next.value] -= 1
    end
    model.constrmap[ci.value] = 0
    model.name_to_con = nothing
    if haskey(model.con_to_name, ci)
        delete!(model.con_to_name, ci)
    end
end

function MOI.modify(model::AbstractModel, ci::CI, change::MOI.AbstractFunctionModification)
    _modify(model, ci, getconstrloc(model, ci), change)
end

function MOI.set(model::AbstractModel, ::MOI.ConstraintFunction, ci::CI, change::MOI.AbstractFunction)
    _modify(model, ci, getconstrloc(model, ci), change)
end
function MOI.set(model::AbstractModel, ::MOI.ConstraintSet, ci::CI, change::MOI.AbstractSet)
    _modify(model, ci, getconstrloc(model, ci), change)
end

MOI.get(model::AbstractModel, noc::MOI.NumberOfConstraints) = _getnoc(model, noc)

function MOI.get(model::AbstractModel, loc::MOI.ListOfConstraints)
    broadcastvcat(_getloc, model)
end

function MOI.get(model::AbstractModel, loc::MOI.ListOfConstraintIndices)
    broadcastvcat(constrs -> _getlocr(constrs, loc), model)
end

function MOI.get(model::AbstractModel, ::MOI.ConstraintFunction, ci::CI)
    _getfunction(model, ci, getconstrloc(model, ci))
end

function MOI.get(model::AbstractModel, ::MOI.ConstraintSet, ci::CI)
    _getset(model, ci, getconstrloc(model, ci))
end

function MOI.is_empty(model::AbstractModel)
    isempty(model.name) && !model.senseset && !model.objectiveset &&
    isempty(model.objective.terms) && iszero(model.objective.constant) &&
    iszero(model.num_variables_created) && iszero(model.nextconstraintid)
end

function MOI.copy_to(dest::AbstractModel, src::MOI.ModelLike; kws...)
    return automatic_copy_to(dest, src; kws...)
end
supports_default_copy_to(model::AbstractModel, copy_names::Bool) = true

# Allocate-Load Interface
# Even if the model does not need it and use default_copy_to, it could be used
# by a layer that needs it
supports_allocate_load(model::AbstractModel, copy_names::Bool) = true

function allocate_variables(model::AbstractModel, nvars)
    return MOI.add_variables(model, nvars)
end
allocate(model::AbstractModel, attr...) = MOI.set(model, attr...)
function allocate_constraint(model::AbstractModel, f::MOI.AbstractFunction,
                             s::MOI.AbstractSet)
    return MOI.add_constraint(model, f, s)
end

function load_variables(::AbstractModel, nvars) end
function load(::AbstractModel, attr...) end
function load_constraint(::AbstractModel, ::CI, ::MOI.AbstractFunction,
                         ::MOI.AbstractSet)
end

# Can be used to access constraints of a model
"""
broadcastcall(f::Function, model::AbstractModel)

Calls `f(contrs)` for every vector `constrs::Vector{ConstraintIndex{F, S}, F, S}` of the model.

# Examples

To add all constraints of the model to a solver `solver`, one can do
```julia
_addcon(solver, ci, f, s) = MOI.add_constraint(solver, f, s)
function _addcon(solver, constrs::Vector)
    for constr in constrs
        _addcon(solver, constr...)
    end
end
MOIU.broadcastcall(constrs -> _addcon(solver, constrs), model)
```
"""
function broadcastcall end

"""
broadcastvcat(f::Function, model::AbstractModel)

Calls `f(contrs)` for every vector `constrs::Vector{ConstraintIndex{F, S}, F, S}` of the model and concatenate the results with `vcat` (this is used internally for `ListOfConstraints`).

# Examples

To get the list of all functions:
```julia
_getfun(ci, f, s) = f
_getfun(cindices::Tuple) = _getfun(cindices...)
_getfuns(constrs::Vector) = _getfun.(constrs)
MOIU.broadcastvcat(_getfuns, model)
```
"""
function broadcastvcat end

# Macro to generate Model
abstract type Constraints{F} end

abstract type SymbolFS end
struct SymbolFun <: SymbolFS
    s::Union{Symbol, Expr}
    typed::Bool
    cname::Expr # `esc(scname)` or `esc(vcname)`
end
struct SymbolSet <: SymbolFS
    s::Union{Symbol, Expr}
    typed::Bool
end

# QuoteNode prevents s from being interpolated and keeps it as a symbol
# Expr(:., MOI, s) would be MOI.s
# Expr(:., MOI, $s) would be Expr(:., MOI, EqualTo)
# Expr(:., MOI, :($s)) would be Expr(:., MOI, :EqualTo)
# Expr(:., MOI, :($(QuoteNode(s)))) is Expr(:., MOI, :(:EqualTo)) <- what we want

# (MOI, :Zeros) -> :(MOI.Zeros)
# (:Zeros) -> :(MOI.Zeros)
_set(s::SymbolSet) = esc(s.s)
_fun(s::SymbolFun) = esc(s.s)
function _typedset(s::SymbolSet)
    if s.typed
        :($(_set(s)){T})
    else
        _set(s)
    end
end
function _typedfun(s::SymbolFun)
    if s.typed
        :($(_fun(s)){T})
    else
        _fun(s)
    end
end

# Base.lowercase is moved to Unicode.lowercase in Julia v0.7
if VERSION >= v"0.7.0-DEV.2813"
    using Unicode
end
_field(s::SymbolFS) = Symbol(replace(lowercase(string(s.s)), "." => "_"))

_getC(s::SymbolSet) = :(ConstraintEntry{F, $(_typedset(s))})
_getC(s::SymbolFun) = _typedfun(s)

_getCV(s::SymbolSet) = :($(_getC(s))[])
_getCV(s::SymbolFun) = :($(s.cname){T, $(_getC(s))}())

_callfield(f, s::SymbolFS) = :($f(model.$(_field(s))))
_broadcastfield(b, s::SymbolFS) = :($b(f, model.$(_field(s))))

"""
macro model(modelname, scalarsets, typedscalarsets, vectorsets, typedvectorsets, scalarfunctions, typedscalarfunctions, vectorfunctions, typedvectorfunctions)

Creates a type `modelname` implementing the MOI model interface and containing `scalarsets` scalar sets `typedscalarsets` typed scalar sets, `vectorsets` vector sets, `typedvectorsets` typed vector sets, `scalarfunctions` scalar functions, `typedscalarfunctions` typed scalar functions, `vectorfunctions` vector functions and `typedvectorfunctions` typed vector functions.
To give no set/function, write `()`, to give one set `S`, write `(S,)`.

This implementation of the MOI model certifies that the constraint indices, in addition to being different between constraints `F`-in-`S` for the same types `F` and `S`,
are also different between constraints for different types `F` and `S`.
This means that for constraint indices `ci1`, `ci2` of this model, `ci1 == ci2` if and only if `ci1.value == ci2.value`.
This fact can be used to use the the value of the index directly in a dictionary representing a mapping between constraint indices and something else.

### Examples

The model describing an linear program would be:
```julia
@model(LPModel,                                                   # Name of model
      (),                                                         # untyped scalar sets
      (MOI.EqualTo, MOI.GreaterThan, MOI.LessThan, MOI.Interval), #   typed scalar sets
      (MOI.Zeros, MOI.Nonnegatives, MOI.Nonpositives),            # untyped vector sets
      (),                                                         #   typed vector sets
      (MOI.SingleVariable,),                                      # untyped scalar functions
      (MOI.ScalarAffineFunction,),                                #   typed scalar functions
      (MOI.VectorOfVariables,),                                   # untyped vector functions
      (MOI.VectorAffineFunction,))                                #   typed vector functions
```

Let `MOI` denote `MathOptInterface`, `MOIU` denote `MOI.Utilities` and
`MOIU.ConstraintEntry{F, S}` be defined as `MOI.Tuple{CI{F, S}, F, S}`.
The macro would create the types:
```julia
struct LPModelScalarConstraints{T, F <: MOI.AbstractScalarFunction} <: MOIU.Constraints{F}
    equalto::Vector{MOIU.ConstraintEntry{F, MOI.EqualTo{T}}}
    greaterthan::Vector{MOIU.ConstraintEntry{F, MOI.GreaterThan{T}}}
    lessthan::Vector{MOIU.ConstraintEntry{F, MOI.LessThan{T}}}
    interval::Vector{MOIU.ConstraintEntry{F, MOI.Interval{T}}}
end
struct LPModelVectorConstraints{T, F <: MOI.AbstractVectorFunction} <: MOIU.Constraints{F}
    zeros::Vector{MOIU.ConstraintEntry{F, MOI.Zeros}}
    nonnegatives::Vector{MOIU.ConstraintEntry{F, MOI.Nonnegatives}}
    nonpositives::Vector{MOIU.ConstraintEntry{F, MOI.Nonpositives}}
end
mutable struct LPModel{T} <: MOIU.AbstractModel{T}
    name::String
    sense::MOI.OptimizationSense
    objective::Union{MOI.SingleVariable, MOI.ScalarAffineFunction{T}, MOI.ScalarQuadraticFunction{T}}
    num_variables_created::Int64
    variable_indices::Union{Nothing, Set{MOI.VariableIndex}}
    var_to_name::Dict{MOI.VariableIndex, String}
    name_to_var::Union{Dict{String, MOI.VariableIndex}, Nothing}
    nextconstraintid::Int64
    con_to_name::Dict{MOI.ConstraintIndex, String}
    name_to_con::Union{Dict{String, MOI.ConstraintIndex}, Nothing}
    constrmap::Vector{Int}
    singlevariable::LPModelScalarConstraints{T, MOI.SingleVariable}
    scalaraffinefunction::LPModelScalarConstraints{T, MOI.ScalarAffineFunction{T}}
    vectorofvariables::LPModelVectorConstraints{T, MOI.VectorOfVariables}
    vectoraffinefunction::LPModelVectorConstraints{T, MOI.VectorAffineFunction{T}}
end
```
The type `LPModel` implements the MathOptInterface API except methods specific to solver models like `optimize!` or `getattribute` with `VariablePrimal`.
"""
macro model(modelname, ss, sst, vs, vst, sf, sft, vf, vft)
    scalarsets = [SymbolSet.(ss.args, false); SymbolSet.(sst.args, true)]
    vectorsets = [SymbolSet.(vs.args, false); SymbolSet.(vst.args, true)]

    scname = esc(Symbol(string(modelname) * "ScalarConstraints"))
    vcname = esc(Symbol(string(modelname) * "VectorConstraints"))
    esc_modelname = esc(modelname)

    scalarfuns = [SymbolFun.(sf.args, false, Ref(scname));
                  SymbolFun.(sft.args, true, Ref(scname))]
    vectorfuns = [SymbolFun.(vf.args, false, Ref(vcname));
                  SymbolFun.(vft.args, true, Ref(vcname))]
    funs = [scalarfuns; vectorfuns]

    scalarconstraints = :(struct $scname{T, F<:$MOI.AbstractScalarFunction} <: Constraints{F}; end)
    vectorconstraints = :(struct $vcname{T, F<:$MOI.AbstractVectorFunction} <: Constraints{F}; end)
    for (c, sets) in ((scalarconstraints, scalarsets), (vectorconstraints, vectorsets))
        for s in sets
            field = _field(s)
            push!(c.args[3].args, :($field::Vector{$(_getC(s))}))
        end
    end

    modeldef = quote
        mutable struct $esc_modelname{T} <: AbstractModel{T}
            name::String
            senseset::Bool
            sense::$MOI.OptimizationSense
            objectiveset::Bool
            objective::Union{$MOI.SingleVariable, $MOI.ScalarAffineFunction{T}, $MOI.ScalarQuadraticFunction{T}}
            num_variables_created::Int64
            # If nothing, no variable has been deleted so the indices of the
            # variables are VI.(1:num_variables_created)
            variable_indices::Union{Nothing, Set{$VI}}
            var_to_name::Dict{$VI, String}
            # If nothing, the dictionary hasn't been constructed yet.
            name_to_var::Union{Dict{String, $VI}, Nothing}
            nextconstraintid::Int64
            con_to_name::Dict{$CI, String}
            name_to_con::Union{Dict{String, $CI}, Nothing}
            constrmap::Vector{Int} # Constraint Reference value ci -> index in array in Constraints
        end
    end
    for f in funs
        cname = f.cname
        field = _field(f)
        push!(modeldef.args[2].args[3].args, :($field::$cname{T, $(_getC(f))}))
    end

    code = quote
        function $MOIU.broadcastcall(f::Function, model::$esc_modelname)
            $(Expr(:block, _broadcastfield.(Ref(:(broadcastcall)), funs)...))
        end
        function $MOIU.broadcastvcat(f::Function, model::$esc_modelname)
            vcat($(_broadcastfield.(Ref(:(broadcastvcat)), funs)...))
        end
        function $MOI.empty!(model::$esc_modelname{T}) where T
            model.name = ""
            model.senseset = false
            model.sense = $MOI.FeasibilitySense
            model.objectiveset = false
            model.objective = $SAF{T}(MOI.ScalarAffineTerm{T}[], zero(T))
            model.num_variables_created = 0
            model.variable_indices = nothing
            empty!(model.var_to_name)
            model.name_to_var = nothing
            model.nextconstraintid = 0
            empty!(model.con_to_name)
            model.name_to_con = nothing
            empty!(model.constrmap)
            $(Expr(:block, _callfield.(Ref(:($MOI.empty!)), funs)...))
        end
    end
    for (cname, sets) in ((scname, scalarsets), (vcname, vectorsets))
        code = quote
            $code
            function $MOIU.broadcastcall(f::Function, model::$cname)
                $(Expr(:block, _callfield.(:f, sets)...))
            end
            function $MOIU.broadcastvcat(f::Function, model::$cname)
                vcat($(_callfield.(:f, sets)...))
            end
            function $MOI.empty!(model::$cname)
                $(Expr(:block, _callfield.(Ref(:(Base.empty!)), sets)...))
            end
        end
    end

    for (funct, T) in ((:_add_constraint, CI), (:_modify, CI), (:_delete, CI), (:_getindex, CI), (:_getfunction, CI), (:_getset, CI), (:_getnoc, MOI.NumberOfConstraints))
        for (c, sets) in ((scname, scalarsets), (vcname, vectorsets))
            for s in sets
                set = _set(s)
                field = _field(s)
                code = quote
                    $code
                    $MOIU.$funct(model::$c, ci::$T{F, <:$set}, args...) where F = $funct(model.$field, ci, args...)
                end
            end
        end

        for f in funs
            fun = _fun(f)
            field = _field(f)
            code = quote
                $code
                $MOIU.$funct(model::$esc_modelname, ci::$T{<:$fun}, args...) = $funct(model.$field, ci, args...)
            end
        end
    end

    code = quote
        $scalarconstraints
        function $scname{T, F}() where {T, F}
            $scname{T, F}($(_getCV.(scalarsets)...))
        end

        $vectorconstraints
        function $vcname{T, F}() where {T, F}
            $vcname{T, F}($(_getCV.(vectorsets)...))
        end

        $modeldef
        function $esc_modelname{T}() where T
            $esc_modelname{T}("", false, $MOI.FeasibilitySense, false, $SAF{T}($MOI.ScalarAffineTerm{T}[], zero(T)),
                              0, nothing, Dict{$VI, String}(), nothing,
                              0, Dict{$CI, String}(), nothing, Int[],
                              $(_getCV.(funs)...))
        end

        $MOI.supports_constraint(model::$esc_modelname{T}, ::Type{<:Union{$(_typedfun.(scalarfuns)...)}}, ::Type{<:Union{$(_typedset.(scalarsets)...)}}) where T = true
        $MOI.supports_constraint(model::$esc_modelname{T}, ::Type{<:Union{$(_typedfun.(vectorfuns)...)}}, ::Type{<:Union{$(_typedset.(vectorsets)...)}}) where T = true

        $code
    end
    return code
end
