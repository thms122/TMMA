"""
CloudLab Profile for 10-node benchmark setup.

Each node:
- Boots Ubuntu 22.04 LTS
- Clones a git repository to /local/repository
- Runs setup.sh from that repository
"""

import geni.portal as portal
import geni.rspec.pg as pg

# Create portal context
pc = portal.Context()

# Create request RSpec
request = pc.makeRequestRSpec()

# Configuration: 10 nodes
NUM_NODES = 10

# Git repository URL containing profile and setup scripts
GIT_REPO_URL = "https://github.com/thms122/TMMA.git"

# Loop to add all nodes
for i in range(NUM_NODES):
    node_name = "node%d" % (i + 1)
    node = request.RawPC(node_name)

    # Set the OS to Ubuntu 22.04 LTS
    node.hardware_type = "c220g5"  # choose appropriate hardware type
    node.disk_image = "urn:publicid:IDN+emulab.net+image+emulab-ops:UBUNTU22-64-STD"

    # Service: clone git repo
    clone_command = "git clone %s /local/repository || (cd /local/repository && git pull)" % GIT_REPO_URL
    node.addService(pg.Execute(shell="sh", command=clone_command))

    # Service: run setup.sh
    node.addService(pg.Execute(shell="sh", command="/local/repository/startup.sh"))

# Print the RSpec
pc.printRequestRSpec(request)
