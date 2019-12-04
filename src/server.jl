struct Server
    config::Config
    jobs::Vector{AbstractJob}
    listener::GitHub.CommentListener

    function Server(config::Config)
        jobs = Vector{AbstractJob}()

        # This closure is the CommentListener's handle function, which validates the
        # trigger phrase and converts the event payload into a J <: AbstractJob. This
        # job then gets added to the `jobs` queue, which is monitored and resolved by
        # the job-feeding tasks scheduled when `run` is called on the Server.
        handle = (event, phrase) -> begin
            nodelog(config, 1, "received job submission with phrase $phrase")
            if event.kind == "issue_comment" && !haskey(event.payload["issue"], "pull_request")
                return HTTP.Response(400, "nanosoldier jobs cannot be triggered from issue comments (only PRs or commits)")
            end
            if haskey(event.payload, "action") && !in(event.payload["action"], ("created", "opened"))
                return HTTP.Response(204, "no action taken (submission was from an edit, close, or delete)")
            end
            submission = JobSubmission(config, event, phrase.match)
            addedjob = false
            for J in subtypes(AbstractJob)
                if isvalid(submission, J)
                    try
                        job = J(submission)
                        push!(jobs, job)
                        reply_status(job, "pending", "job added to queue: $(summary(job))")
                        addedjob = true
                    catch err
                        nodelog(config, 1, "failed to constuct $J with a supposedly valid submission: $err",
                                error=(err, stacktrace(catch_backtrace())))
                    end
                end
            end
            if !addedjob
                reply_status(submission, "error", "invalid job submission; check syntax")
                HTTP.Response(400, "invalid job submission")
            end
            return HTTP.Response(202, "received job submission")
        end

        listener = GitHub.CommentListener(handle, config.trigger;
                                          auth = config.auth,
                                          secret = config.secret,
                                          repos = [config.trackrepo])
        return new(config, jobs, listener)
    end
end

function Base.run(server::Server, args...; kwargs...)
    @assert myid() == 1 "Nanosoldier server must be run from the master node"
    persistdir!(workdir(server.config))
    # Schedule a task for each node that feeds the node a job from the
    # queque once the node has completed its primary job. If the queue is
    # empty, then the task will call `yield` in order to avoid a deadlock.
    for node in server.config.nodes
        @async begin
            try
                while true
                    job = retrieve_job!(server.jobs, node == last(server.config.nodes))
                    if job !== nothing
                        delegate_job(server, job, node)
                    else
                        yield()
                    end
                    sleep(5) # poll only every 5 seconds so as not to throttle CPU
                end
            catch err
                nodelog(server.config, node, "encountered job loop error: $err",
                        error=(err, stacktrace(catch_backtrace())))
            end
        end
    end
    return run(server.listener, args...; kwargs...)
end

function retrieve_job!(jobs, accept_daily::Bool)
    if isempty(jobs)
        return nothing
    else
        if !accept_daily
            i = findfirst(job -> !(isa(job, BenchmarkJob) && job.isdaily), jobs)
            if i === nothing
                return nothing
            else
                job = jobs[i]
                deleteat!(jobs, i)
                return job
            end
        else
            return popfirst!(jobs)
        end
    end
end

function delegate_job(server::Server, job::AbstractJob, node)
    message = "running on node $(node): $(summary(job))"
    reply_status(job, "pending", message)
    nodelog(server.config, node, message)
    try
        remotecall_fetch(persistdir!, node, server.config)
        remotecall_fetch(run, node, job)
        nodelog(server.config, node, "completed job: $(summary(job))")
    catch err
        err = isa(err, RemoteException) ? err.captured.ex : err
        err_str = string(err)
        message = "Something went wrong when running [your job]($(submission(job).url)):\n```\n$(err_str)\n```\n"
        if isa(err, NanosoldierError)
            if isempty(err.url)
                message *= "Unfortunately, the logs could not be uploaded.\n"
            else
                message *= "Logs and partial data can be found [here]($(err.url))\n"
            end
        end
        message *= "cc @ararslan"
        nodelog(server.config, node, err_str, error=(err, stacktrace(catch_backtrace())))
        reply_status(job, "error", err_str)
        reply_comment(job, message)
    end
end
