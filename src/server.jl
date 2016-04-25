
immutable Server
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
            if event.kind == "issue_comment" && !(haskey(event.payload["issue"], "pull_request"))
                return HttpCommon.Response(400, "Nanosoldier jobs cannot be triggered from issue comments (only PRs or commits)")
            end
            submission = JobSubmission(config, event, phrase)
            addedjob = false
            for J in subtypes(AbstractJob)
                if isvalid(submission, J)
                    job = J(submission)
                    push!(jobs, job)
                    reply_status(job, "pending", "job added to queue: $(summary(job))")
                    addedjob = true
                end
            end
            if !(addedjob)
                reply_status(submission, "error", "invalid job submission")
                HttpCommon.Response(400, "invalid job submission")
            end
            return HttpCommon.Response(202, "recieved job submission")
        end

        listener = GitHub.CommentListener(handle, TRIGGER;
                                          auth = config.auth,
                                          secret = config.secret,
                                          repos = [config.trackrepo])
        return new(config, jobs, listener)
    end
end

function Base.run(server::Server, args...; kwargs...)
    @assert myid() == 1 "Nanosoldier server must be run from the master node"
    persistdir!(workdir(server.config))
    persistdir!(resultdir(server.config))
    persistdir!(logdir(server.config))
    # Schedule a task for each node that feeds the node a job from the
    # queque once the node has completed its primary job. If the queue is
    # empty, then the task will call `yield` in order to avoid a deadlock.
    for node in server.config.nodes
        @schedule begin
            try
                while true
                    if isempty(server.jobs)
                        yield()
                    else
                        job = shift!(server.jobs)
                        reply_status(job, "pending", "running on node $(node): $(summary(job))")
                        try
                            remotecall_fetch(run, node, job)
                        catch err
                            message = "encountered error: $(err)"
                            nodelog(server.config, node, message)
                            reply_status(job)
                        end
                    end
                    sleep(10) # poll every 10 seconds so as not to throttle CPU
                end
            catch err
                nodelog(server.config, node, "encountered task error: $(err)")
                throw(err)
            end
        end
    end
    return run(server.listener, args...; kwargs...)
end
