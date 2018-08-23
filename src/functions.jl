# Functions

"""
    AbstractFunction

Abstract supertype for function objects.
"""
abstract type AbstractFunction end

"""
    output_dimension(f::AbstractFunction)

Return 1 if `f` has a scalar output and the number of output components if `f`
has a vector output.
"""
function output_dimension end

"""
    AbstractScalarFunction

Abstract supertype for scalar-valued function objects.
"""
abstract type AbstractScalarFunction <: AbstractFunction end
output_dimension(::AbstractScalarFunction) = 1

"""
    AbstractVectorFunction

Abstract supertype for vector-valued function objects.
"""
abstract type AbstractVectorFunction <: AbstractFunction end


"""
    SingleVariable(variable)

The function that extracts the scalar variable referenced by `variable`, a `VariableIndex`.
This function is naturally be used for single variable bounds or integrality constraints.
"""
struct SingleVariable <: AbstractScalarFunction
    variable::VariableIndex
end

"""
    VectorOfVariables(variables)

The function that extracts the vector of variables referenced by `variables`, a `Vector{VariableIndex}`.
This function is naturally be used for constraints that apply to groups of variables, such as an "all different" constraint, an indicator constraint, or a complementarity constraint.
"""
struct VectorOfVariables <: AbstractVectorFunction
    variables::Vector{VariableIndex}
end
output_dimension(f::VectorOfVariables) = length(f.variables)

"""
    struct ScalarAffineTerm{T}
        coefficient::T
        variable_index::VariableIndex
    end

Represents ``c x_i`` where ``c`` is `coefficient` and ``x_i`` is the variable
identified by `variable_index`.
"""
struct ScalarAffineTerm{T}
    coefficient::T
    variable_index::VariableIndex
end

# Note: ScalarAffineFunction is mutable because its `constant` field is likely of an immutable
# type, while its `terms` field is of a mutable type, meaning that creating a `ScalarAffineFunction`
# allocates, and it is desirable to provide a zero-allocation option for working with
# ScalarAffineFunctions. See https://github.com/JuliaOpt/MathOptInterface.jl/pull/343.
"""
    ScalarAffineFunction{T}(terms, constant)

The scalar-valued affine function ``a^T x + b``, where:
* ``a`` is a sparse vector specified by a list of
  [`ScalarAffineTerm`](@ref) structs.
* ``b`` is a scalar specified by `constant::T`

Duplicate variable indices in `terms` are accepted, and the corresponding
coefficients are summed together.
"""
mutable struct ScalarAffineFunction{T} <: AbstractScalarFunction
    terms::Vector{ScalarAffineTerm{T}}
    constant::T
end

"""
    struct VectorAffineTerm{T}
        output_index::Int64
        scalar_term::ScalarAffineTerm{T}
    end

A `ScalarAffineTerm` plus its index of the output component of a
`VectorAffineFunction` or `VectorQuadraticFunction`.
`output_index` can also be interpreted as a row index into a sparse matrix,
where the `scalar_term` contains the column index and coefficient.
"""
struct VectorAffineTerm{T}
    output_index::Int64
    scalar_term::ScalarAffineTerm{T}
end

function VectorAffineTerm(output_index::Base.Integer, scalar_term::ScalarAffineTerm)
    VectorAffineTerm(convert(Int64, output_index), scalar_term)
end

"""
    VectorAffineFunction{T}(terms, constants)

The vector-valued affine function ``A x + b``, where:
* ``A`` is a sparse matrix specified by a list of `VectorAffineTerm` objects.
* ``b`` is a vector specified by `constants`

Duplicate indices in the ``A`` are accepted, and the corresponding coefficients
are summed together.
"""
struct VectorAffineFunction{T} <: AbstractVectorFunction
    terms::Vector{VectorAffineTerm{T}}
    constants::Vector{T}
end
output_dimension(f::VectorAffineFunction) = length(f.constants)

"""
    struct ScalarQuadraticTerm{T}
        coefficient::T
        variable_index_1::VariableIndex
        variable_index_2::VariableIndex
    end

Represents ``c x_i x_j`` where ``c`` is `coefficient`, ``x_i`` is the variable
identified by `variable_index_1` and ``x_j`` is the variable identified by
`variable_index_2`.
"""
struct ScalarQuadraticTerm{T}
    coefficient::T
    variable_index_1::VariableIndex
    variable_index_2::VariableIndex
end

# Note: ScalarQuadraticFunction is mutable because its `constant` field is likely of an immutable
# type, while its other fields are of mutable types, meaning that creating a `ScalarQuadraticFunction`
# allocates, and it is desirable to provide a zero-allocation option for working with
# ScalarQuadraticFunctions. See https://github.com/JuliaOpt/MathOptInterface.jl/pull/343.
"""
    ScalarQuadraticFunction{T}(affine_terms, quadratic_terms, constant)

The scalar-valued quadratic function ``\\frac{1}{2}x^TQx + a^T x + b``, where:
* ``a`` is a sparse vector specified by a list of `ScalarAffineTerm` structs.
* ``b`` is a scalar specified by `constant`.
* ``Q`` is a symmetric matrix specified by a list of `ScalarQuadraticTerm`
  structs.

Duplicate indices in ``a`` or ``Q`` are accepted, and the corresponding
coefficients are summed together. "Mirrored" indices `(q,r)` and `(r,q)` (where
`r` and `q` are `VariableIndex`es) are considered duplicates; only one need be
specified.
"""
mutable struct ScalarQuadraticFunction{T} <: AbstractScalarFunction
    affine_terms::Vector{ScalarAffineTerm{T}}
    quadratic_terms::Vector{ScalarQuadraticTerm{T}}
    constant::T
end

"""
    struct VectorQuadraticTerm{T}
        output_index::Int64
        scalar_term::ScalarQuadraticTerm{T}
    end

A [`ScalarQuadraticTerm`](@ref) plus its index of the output component of a
`VectorQuadraticFunction`. Each output component corresponds to a
distinct sparse matrix ``Q_i``.
"""
struct VectorQuadraticTerm{T}
    output_index::Int64
    scalar_term::ScalarQuadraticTerm{T}
end

function VectorQuadraticTerm(output_index::Base.Integer, scalar_term::ScalarQuadraticTerm)
    VectorQuadraticTerm(convert(Int64, output_index), scalar_term)
end


"""
    VectorQuadraticFunction{T}(affine_terms, quadratic_terms, constant)

The vector-valued quadratic function with i`th` component ("output index")
defined as ``\\frac{1}{2}x^TQ_ix + a_i^T x + b_i``, where:
* ``a_i`` is a sparse vector specified by the `VectorAffineTerm`s with
  `output_index == i`.
* ``b_i`` is a scalar specified by `constants[i]`
* ``Q_i`` is a symmetric matrix specified by the `VectorQuadraticTerm` with
  `output_index == i`.

Duplicate indices in ``a_i`` or ``Q_i`` are accepted, and the corresponding
coefficients are summed together. "Mirrored" indices `(q,r)` and `(r,q)` (where
`r` and `q` are `VariableIndex`es) are considered duplicates; only one need be
specified.
"""
struct VectorQuadraticFunction{T} <: AbstractVectorFunction
    affine_terms::Vector{VectorAffineTerm{T}}
    quadratic_terms::Vector{VectorQuadraticTerm{T}}
    constants::Vector{T}
end
output_dimension(f::VectorQuadraticFunction) = length(f.constants)

# Function modifications


"""
    AbstractFunctionModification

An abstract supertype for structs which specify partial modifications to functions, to be used for making small modifications instead of replacing the functions entirely.
"""
abstract type AbstractFunctionModification end

"""
    ScalarConstantChange{T}(new_constant::T)

A struct used to request a change in the constant term of a scalar-valued function.
Applicable to `ScalarAffineFunction` and `ScalarQuadraticFunction`.
"""
struct ScalarConstantChange{T} <: AbstractFunctionModification
    new_constant::T
end

"""
    VectorConstantChange{T}(new_constant::Vector{T})

A struct used to request a change in the constant vector of a vector-valued function.
Applicable to `VectorAffineFunction` and `VectorQuadraticFunction`.
"""
struct VectorConstantChange{T} <: AbstractFunctionModification
    new_constant::Vector{T}
end

"""
    ScalarCoefficientChange{T}(variable::VariableIndex, new_coefficient::T)

A struct used to request a change in the linear coefficient of a single variable
in a scalar-valued function.
Applicable to `ScalarAffineFunction` and `ScalarQuadraticFunction`.
"""
struct ScalarCoefficientChange{T} <: AbstractFunctionModification
    variable::VariableIndex
    new_coefficient::T
end

# Note: MultiRowChange is mutable because its `variable` field of an immutable
# type, while `new_coefficients` is of a mutable type, meaning that creating a `MultiRowChange`
# allocates, and it is desirable to provide a zero-allocation option for working with
# MultiRowChanges. See https://github.com/JuliaOpt/MathOptInterface.jl/pull/343.
"""
    MultirowChange{T}(variable::VariableIndex, new_coefficients::Vector{Tuple{Int64, T}})

A struct used to request a change in the linear coefficients of a single
variable in a vector-valued function. New coefficients are specified by
`(output_index, coefficient)` tuples. Applicable to `VectorAffineFunction` and
`VectorQuadraticFunction`.
"""
mutable struct MultirowChange{T} <: AbstractFunctionModification
    variable::VariableIndex
    new_coefficients::Vector{Tuple{Int64, T}}
end

function MultirowChange(variable::VariableIndex, new_coefficients::Vector{Tuple{Ti, T}}) where {Ti<:Base.Integer, T}
    MultirowChange(variable, [(convert(Int64, i), j) for (i,j) in new_coefficients])
end

# Implementation of comparison for MOI functions
Base.:(==)(f::VectorOfVariables, g::VectorOfVariables) = f.variables == g.variables

Base.isapprox(f::Union{SingleVariable, VectorOfVariables}, g::Union{SingleVariable, VectorOfVariables}; kwargs...) = f == g

# For affine and quadratic functions, terms are compressed in a dictionary using `_dicts` and then the dictionaries are compared with `dict_isapprox`
function dict_isapprox(d1::Dict, d2::Dict{<:Any, T}; kwargs...) where T
    all(kv -> isapprox(kv.second, Base.get(d2, kv.first, zero(T)); kwargs...), d1)
end

# Build a dictionary where the duplicate keys are summed
function sum_dict(kvs::Vector{Pair{K, V}}) where {K, V}
    d = Dict{K, V}()
    for kv in kvs
        key = kv.first
        d[key] = kv.second + Base.get(d, key, zero(V))
    end
    d
end

"""
    coefficient(t::Union{ScalarAffineTerm, ScalarQuadraticTerm
                         VectorAffineTerm, VectorQuadraticTerm})

Finds the coefficient stored in the term `t`.
"""
function coefficient end

function coefficient(t::Union{ScalarAffineTerm, ScalarQuadraticTerm})
    return t.coefficient
end
function coefficient(t::Union{VectorAffineTerm, VectorQuadraticTerm})
    return t.scalar_term.coefficient
end

"""
    term_indices(t::Union{ScalarAffineTerm, ScalarQuadraticTerm,
                         VectorAffineTerm, VectorQuadraticTerm})

Returns the indices of the input term `t` as a tuple of `Int`s.

* For `t::ScalarAffineTerm`, this is a 1-tuple of the variable index.
* For `t::ScalarQuadraticTerm`, this is a 2-tuple of the variable indices
  in non-decreasing order.
* For `t::VectorAffineTerm`, this is a 2-tuple of the row/output and
  variable indices.
* For `t::VectorQuadraticTerm`, this is a 3-tuple of the row/output and
  variable indices in non-decreasing order.
"""
term_indices(t::ScalarAffineTerm) = (t.variable_index.value,)
function term_indices(t::ScalarQuadraticTerm)
    return minmax(t.variable_index_1.value, t.variable_index_2.value)
end
function term_indices(t::Union{VectorAffineTerm, VectorQuadraticTerm})
    return (t.output_index, term_indices(t.scalar_term)...)
end

"""
    term_pair(t::Union{ScalarAffineTerm, ScalarQuadraticTerm,
                       VectorAffineTerm, VectorQuadraticTerm})

Returns the pair [`term_indices`](@ref) `=>` [`coefficient`](@ref) of the term.
"""
function term_pair(t::Union{ScalarAffineTerm, ScalarQuadraticTerm,
                            VectorAffineTerm, VectorQuadraticTerm})
    term_indices(t) => coefficient(t)
end

function _dicts(f::Union{ScalarAffineFunction, VectorAffineFunction})
    return (sum_dict(term_pair.(f.terms)),)
end

function _dicts(f::Union{ScalarQuadraticFunction, VectorQuadraticFunction})
    return (sum_dict(term_pair.(f.affine_terms)),
            sum_dict(term_pair.(f.quadratic_terms)))
end

_constant(f::Union{ScalarAffineFunction, ScalarQuadraticFunction}) = f.constant
_constant(f::Union{VectorAffineFunction, VectorQuadraticFunction}) = f.constants

function Base.isapprox(f::F, g::G; kwargs...) where {F<:Union{ScalarAffineFunction, ScalarQuadraticFunction, VectorAffineFunction, VectorQuadraticFunction},
                                                     G<:Union{ScalarAffineFunction, ScalarQuadraticFunction, VectorAffineFunction, VectorQuadraticFunction}}
    isapprox(_constant(f), _constant(g); kwargs...) && all(dict_isapprox.(_dicts(f), _dicts(g); kwargs...))
end

"""
    copy(func::Union{ScalarAffineFunction, VectorAffineFunction})

Return a new affine function with a shallow copy of the terms and constant(s)
from `func`.
"""
Base.copy(func::F) where {F <: Union{ScalarAffineFunction, VectorAffineFunction}} = F(copy(func.terms), copy(_constant(func)))

"""
    copy(func::Union{ScalarQuadraticFunction, VectorQuadraticFunction})

Return a new quadratic function with a shallow copy of the terms and constant(s)
from `func`.
"""
Base.copy(func::F) where {F <: Union{ScalarQuadraticFunction, VectorQuadraticFunction}} = F(copy(func.affine_terms), copy(func.quadratic_terms), copy(_constant(func)))
