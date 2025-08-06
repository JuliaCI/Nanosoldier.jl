import GitHub

auth = GitHub.authenticate(ENV["GITHUB_AUTH"])
repo = "JuliaLang/julia"
sha = GitHub.branch(repo, "master").commit.sha

message = """
          Executing the daily benchmark build, I will reply here when finished:

          @nanosoldier `runbenchmarks(isdaily = true, priority = "low")`
          """
get(ENV, "BENCHMARK", "true") == "true" &&
    GitHub.create_comment(repo, sha, :commit, auth=auth, params=Dict("body" => message))

message = """
          Executing the daily package evaluation, I will reply here when finished:

          @nanosoldier `runtests(isdaily = true, priority = "low")`
          """
get(ENV, "PKGEVAL", "true") == "true" &&
    GitHub.create_comment(repo, sha, :commit, auth=auth, params=Dict("body" => message))
