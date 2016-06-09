import GitHub

auth = GitHub.authenticate(ENV["GITHUB_AUTH"])
repo = "JuliaLang/julia"
sha = get(get(GitHub.branch(repo, "master").commit).sha)
message = """
          Executing the daily benchmark build, I will reply here when finished:

          @nanosoldier `runbenchmarks(ALL, isdaily = true)`
          """

GitHub.create_comment(repo, sha, :commit, auth = auth, params = Dict("body" => message))
