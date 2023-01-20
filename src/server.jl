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
            nodelog(config, 1, "considering job submission with phrase $phrase")
            if event.kind == "issue_comment" && !haskey(event.payload["issue"], "pull_request")
                return HTTP.Response(400, "nanosoldier jobs cannot be triggered from issue comments (only PRs or commits)")
            end
            if haskey(event.payload, "action") && !in(event.payload["action"], ("created", "opened"))
                return HTTP.Response(204, "no action taken (submission was from an edit, close, or delete)")
            end

            # TODO: JobSubmission construction can fail (e.g., in case of duplicate kwargs)
            submission = JobSubmission(config, event, phrase.match)

            try
                J = if submission.func == "runtests"
                    PkgEvalJob
                elseif submission.func == "runbenchmarks"
                    BenchmarkJob
                else
                    nanosoldier_error("unrecognized job command `$(submission.func)`")
                end

                job = J(submission)

                push!(jobs, job)
                publish_update(job, "pending", "Accepted")
                nodelog(config, 1, "job added to queue: $(summary(job))")
                return HTTP.Response(202, "received job submission")
            catch err
                # report a simple message to the user (to prevent leaking secrets)
                message = "Your job submission was not accepted"
                if isa(err, NanosoldierError)
                    message *= ": $(err.msg)."
                else
                    message *= ". Consult the server logs for more details"
                    isempty(config.admin) || (message *= " (cc @$(config.admin))")
                    message *= "."
                end
                reply_comment(submission, message)

                # but put all details in the server log
                nodelog(config, 1, "failed submission: $phrase",
                        error=(err, stacktrace(catch_backtrace())))

                return HTTP.Response(400, "invalid job submission")
            end
        end

        listener = GitHub.CommentListener(handle, config.trigger;
                                          auth = config.auth,
                                          secret = config.secret,
                                          check_collab = false)
        return new(config, jobs, listener)
    end
end

function Base.run(server::Server, args...; kwargs...)
    @assert myid() == 1 "Nanosoldier server must be run from the master node"

    nodelog(server.config, 1, "Storing data at '$workdir'")
    persistdir!(workdir)

    if !(server.config.auth isa GitHub.AnonymousAuth)
        user = GitHub.whoami(; auth=server.config.auth)
        nodelog(server.config, 1, "Authenticated as GitHub user '$(user.login)'")
    end

    # Schedule a task for each node that feeds the node a job from the
    # queque once the node has completed its primary job. If the queue is
    # empty, then the task will call `yield` in order to avoid a deadlock.
    for (job_type, job_nodes) in server.config.nodes, node in job_nodes
        @async begin
            # default to using all CPUs
            if !haskey(server.config.cpus, getpid())
                server.config.cpus[getpid()] = Base.OneTo(Sys.CPU_THREADS)
            end

            try
                while true
                    job = retrieve_job!(server.jobs, job_type, node == last(job_nodes))
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

function retrieve_job!(jobs, job_type::Type, accept_daily::Bool)
    if isempty(jobs)
        return nothing
    else
        i = findfirst(job -> isa(job, job_type) && (accept_daily || !job.isdaily), jobs)
        if i === nothing
            return nothing
        else
            job = jobs[i]
            deleteat!(jobs, i)
            return job
        end
    end
end

function delegate_job(server::Server, job::AbstractJob, node)
    publish_update(job, "pending", "Running")
    nodelog(server.config, node, "running on node $(node): $(summary(job))")
    try
        remotecall_fetch(persistdir!, node, server.config)
        remotecall_fetch(run, node, job)
        publish_update(job, "success", "Completed"; fallback=false)
        nodelog(server.config, node, "completed job: $(summary(job))")
    catch err
        # report a simple message to the user (to prevent leaking secrets)
        message = "[Your job]($(submission(job).url)) failed"
        if isa(err, RemoteException) && isa(err.captured.ex, NanosoldierError)
            message *= ": $(err.captured.ex.msg)."
        else
            message *= ". Consult the server logs for more details"
            isempty(server.config.admin) || (message *= " (cc @$(server.config.admin))")
            message *= "."
        end
        reply_comment(submission(job), message)
        publish_update(job, "error", "Failed"; fallback=false)

        # but put all details in the server log
        nodelog(server.config, node, "failed job: $(summary(job))",
                error=(err, stacktrace(catch_backtrace())))
    end
end
