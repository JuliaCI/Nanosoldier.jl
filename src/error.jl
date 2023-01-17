# error handling

export NanosoldierError

# to avoid inadvertently leaking secrets (e.g. originating from the environment of a
# failed process error), we use a know error type of which we'll only report the primary
# message to the user. details of the contained exception will only be logged privately.

mutable struct NanosoldierError <: Exception
    msg::String
    err::Union{Exception,Nothing}

    NanosoldierError(msg, err=nothing) = new(msg, err)
end

nanosoldier_error(msg, err=nothing) = throw(NanosoldierError(msg, err))

function Base.show(io::IO, err::NanosoldierError)
    print(io, "NanosoldierError: ", err.msg)
    if err.err !== nothing && !get(io, :compact, false)
        print(io, ": ")
        showerror(io, err.err)
    end
end
