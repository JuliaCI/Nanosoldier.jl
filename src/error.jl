# error handling

mutable struct NanosoldierError{E<:Exception} <: Exception
    url::String
    msg::String
    err::E
end

NanosoldierError(msg, err::E) where {E<:Exception} = NanosoldierError{E}("", msg, err)

function Base.show(io::IO, err::NanosoldierError)
    print(io, "NanosoldierError: ", err.msg, ": ")
    showerror(io, err.err)
end
