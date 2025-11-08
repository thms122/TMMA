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
pc.defineParameter("nodeCount", "Number of Nodes", portal.ParameterType.INTEGER, 1,
                   longDescription="If you specify more then one node, " +
                   "we will create a lan for you.")

# Configuration: 5 nodes
NUM_NODES = pc.getParameter("nodeCount")

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

    # Make the startup script executable
    chmod_command = "sudo chmod +x /local/repository/colloid_startup.sh"
    node.addService(pg.Execute(shell="sh", command=chmod_command))

    # Service: run colloid_startup.sh
    node.addService(pg.Execute(shell="sh", command="/local/repository/colloid_startup.sh"))

# Print the RSpec
pc.printRequestRSpec(request)

