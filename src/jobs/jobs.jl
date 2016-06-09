# All types `J <: AbstractJob` must implement:
#
# - `J(submission::JobSubmission)`: create an instance of `J` from `submission`
# - `submission(job::J)`: return the `JobSubmission` used to create `job`
# - `isvalid(submission::JobSubmission, ::Type{J})`: return true if `submission` is a valid input for `J`, false otherwise
# - `Base.run(job::J)`: execute `job`
# - `Base.summary(job::J)`: a short string identifying/describing `job`

abstract AbstractJob

reply_status(job::AbstractJob, args...; kwargs...) = reply_status(submission(job), args...; kwargs...)
reply_comment(job::AbstractJob, args...; kwargs...) = reply_comment(submission(job), args...; kwargs...)
upload_report_repo!(job::AbstractJob, args...; kwargs...) = upload_report_repo!(submission(job), args...; kwargs...)

include("BenchmarkJob.jl")
include("PkgEvalJob.jl")
