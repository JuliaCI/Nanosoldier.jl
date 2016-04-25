# All types J <: AbstractJob must implement
#
# J(submission::JobSubmission) --> create an instance of J from this submission
# submission(::J) --> return the submission used to create J
# isvalid(submission::JobSubmission, ::Type{J}) --> return true if J fits this submission, false otherwise
# Base.run(::J) --> execute the job
# Base.summary(::J) --> a short string descrubing the job

abstract AbstractJob

reply_status(job::AbstractJob, args...; kwargs...) = reply_status(submission(job), args...; kwargs...)
reply_comment(job::AbstractJob, args...; kwargs...) = reply_comment(submission(job), args...; kwargs...)
upload_report_file(job::AbstractJob, args...; kwargs...) = upload_report_file(submission(job), args...; kwargs...)

include("BenchmarkJob.jl")
include("PkgEvalJob.jl")
