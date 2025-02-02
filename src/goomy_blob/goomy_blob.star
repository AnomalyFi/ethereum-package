SERVICE_NAME = "goomy-blob-spammer"
IMAGE_NAME = "ethpandaops/goomy-blob:master"

ENTRYPOINT_ARGS = ["/bin/sh", "-c"]

# The min/max CPU/memory that goomy can use
MIN_CPU = 100
MAX_CPU = 1000
MIN_MEMORY = 20
MAX_MEMORY = 300


def launch_goomy_blob(
    plan,
    prefunded_addresses,
    el_client_contexts,
    cl_client_context,
    seconds_per_slot,
    goomy_blob_params,
):
    config = get_config(
        prefunded_addresses,
        el_client_contexts,
        cl_client_context,
        seconds_per_slot,
        goomy_blob_params.goomy_blob_args,
    )
    plan.add_service(SERVICE_NAME, config)


def get_config(
    prefunded_addresses,
    el_client_contexts,
    cl_client_context,
    seconds_per_slot,
    goomy_blob_args,
):
    goomy_cli_args = []
    for index, client in enumerate(el_client_contexts):
        goomy_cli_args.append(
            "-h http://{0}:{1}".format(
                client.ip_addr,
                client.rpc_port_num,
            )
        )

    goomy_args = " ".join(goomy_blob_args)
    if goomy_args == "":
        goomy_args = "combined -b 2 -t 2 --max-pending 3"
    goomy_cli_args.append(goomy_args)

    return ServiceConfig(
        image=IMAGE_NAME,
        entrypoint=ENTRYPOINT_ARGS,
        cmd=[
            " && ".join(
                [
                    "apt-get update",
                    "apt-get install -y curl jq",
                    'current_epoch=$(curl -s http://{0}:{1}/eth/v2/beacon/blocks/head | jq -r ".version")'.format(
                        cl_client_context.ip_addr, cl_client_context.http_port_num
                    ),
                    'while [ $current_epoch != "deneb" ]; do echo "waiting for deneb, current epoch is $current_epoch"; current_epoch=$(curl -s http://{0}:{1}/eth/v2/beacon/blocks/head | jq -r ".version"); sleep {2}; done'.format(
                        cl_client_context.ip_addr,
                        cl_client_context.http_port_num,
                        seconds_per_slot,
                    ),
                    'echo "sleep is over, starting to send blob transactions"',
                    "./blob-spammer -p {0} {1}".format(
                        prefunded_addresses[4].private_key,
                        " ".join(goomy_cli_args),
                    ),
                ]
            )
        ],
        min_cpu=MIN_CPU,
        max_cpu=MAX_CPU,
        min_memory=MIN_MEMORY,
        max_memory=MAX_MEMORY,
    )
