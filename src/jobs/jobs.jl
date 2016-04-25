# All types J <: AbstractJob must implement
#
# J(submission::JobSubmission) --> create an instance of J from this submission
# submission(::J) --> return the submission used to create J
# isvalid(submission::JobSubmission, ::Type{J}) --> return true if J fits this submission, false otherwise
# Base.run(::J) --> execute the job
# Base.summary(::J) --> a short string descrubing the job

abstract AbstractJob

create_status(job::AbstractJob, args...; kwargs...) = create_status(submission(job), args...; kwargs...)
config(job::AbstractJob) = submission(job).config

include("BenchmarkJob.jl")
include("PkgEvalJob.jl")
