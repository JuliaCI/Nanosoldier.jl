# This file contains the default configuration settings for testing the CI
# tracking server that runs on the Nanosoldier cluster.

workers = addprocs(["nanosoldier5"])

import Nanosoldier, GitHub

config = Nanosoldier.Config(Nanosoldier.persistdir!(joinpath(homedir(), "workdir"));
                                  auth = GitHub.authenticate(ENV["GITHUB_AUTH"]),
                                  buildrepo = "jrevels/julia",
                                  reportrepo = "jrevels/BaseBenchmarkReports",
                                  makejobs = 6)
