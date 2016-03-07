# This file contains the default configuration settings for the CI tracking
# server that runs on the Nanosoldier cluster.

workers = addprocs(["nanosoldier6", "nanosoldier7"])

import Nanosoldier, GitHub

config = Nanosoldier.ServerConfig(Nanosoldier.persistdir!(joinpath(homedir(), "workdir"));
                                  auth = GitHub.authenticate(ENV["GITHUB_AUTH"]),
                                  buildrepo = "JuliaLang/julia",
                                  reportrepo = "JuliaCI/BaseBenchmarkReports",
                                  makejobs = 6)
