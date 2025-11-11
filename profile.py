"""
Each node:
- Boots Ubuntu 22.04 LTS
- Clones a git repository to /local/repository
- Runs colloid_startup.sh from that repository
- Optionally attaches a temporary filesystem (/mydata) of requested size
"""

import geni.portal as portal
import geni.rspec.pg as pg

# Create portal context
pc = portal.Context()
request = pc.makeRequestRSpec()

# === Parameters ===
pc.defineParameter("nodeCount", "Number of Nodes",
                   portal.ParameterType.INTEGER, 1,
                   longDescription="If you specify more than one node, a LAN will be created.")

pc.defineParameter("tempFileSystemSize", "Temporary Filesystem Size (GB)",
                   portal.ParameterType.INTEGER, 0,
                   longDescription="The size in GB of a temporary filesystem to mount on each node. "
                                   "Set to 0 to skip adding extra storage.")

params = pc.bindParameters()

# === Configuration ===
NUM_NODES = params.nodeCount
TEMP_SIZE = params.tempFileSystemSize  # in GB
GIT_REPO_URL = "https://github.com/thms122/TMMA.git"

# === Node setup ===
for i in range(NUM_NODES):
    node_name = f"node{i+1}"
    node = request.RawPC(node_name)

    # Set OS and hardware
    node.hardware_type = "c220g5"  # or another available type on your cluster
    node.disk_image = "urn:publicid:IDN+emulab.net+image+emulab-ops:UBUNTU22-64-STD"

    # Optionally add extra temporary filesystem
    if TEMP_SIZE > 0:
        bs = node.Blockstore("bs_" + node_name, "/local")
        bs.size = f"{TEMP_SIZE}GB"

    # Clone and run repo
    clone_cmd = f"git clone {GIT_REPO_URL} /local/repository || (cd /local/repository && git pull)"
    node.addService(pg.Execute(shell="sh", command=clone_cmd))

    chmod_cmd = "sudo chmod +x /local/repository/colloid_startup.sh"
    node.addService(pg.Execute(shell="sh", command=chmod_cmd))

    run_cmd = "/local/repository/colloid_startup.sh"
    node.addService(pg.Execute(shell="sh", command=run_cmd))

# === Print the RSpec ===
pc.printRequestRSpec(request)
