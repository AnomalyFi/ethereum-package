shared_utils = import_module("../shared_utils/shared_utils.star")
postgres = import_module("github.com/kurtosis-tech/postgres-package/main.star")
redis = import_module("github.com/kurtosis-tech/redis-package/main.star")

IMAGE_NAME = "gobitfly/eth2-beaconchain-explorer:latest"

POSTGRES_PORT_ID = "postgres"
POSTGRES_PORT_NUMBER = 5432
POSTGRES_DB = "db"
POSTGRES_USER = "postgres"
POSTGRES_PASSWORD = "pass"

REDIS_PORT_ID = "redis"
REDIS_PORT_NUMBER = 6379

FRONTEND_PORT_ID = "http"
FRONTEND_PORT_NUMBER = 8080

LITTLE_BIGTABLE_PORT_ID = "littlebigtable"
LITTLE_BIGTABLE_PORT_NUMBER = 9000

FULL_BEACONCHAIN_CONFIG_FILENAME = "config.yml"


USED_PORTS = {
    FRONTEND_PORT_ID: shared_utils.new_port_spec(
        FRONTEND_PORT_NUMBER,
        shared_utils.TCP_PROTOCOL,
        shared_utils.HTTP_APPLICATION_PROTOCOL,
    )
}

# The min/max CPU/memory that postgres can use
POSTGRES_MIN_CPU = 10
POSTGRES_MAX_CPU = 1000
POSTGRES_MIN_MEMORY = 32
POSTGRES_MAX_MEMORY = 1024

# The min/max CPU/memory that redis can use
REDIS_MIN_CPU = 10
REDIS_MAX_CPU = 1000
REDIS_MIN_MEMORY = 32
REDIS_MAX_MEMORY = 1024

# The min/max CPU/memory that littlebigtable can use
LITTLE_BIGTABLE_MIN_CPU = 100
LITTLE_BIGTABLE_MAX_CPU = 1000
LITTLE_BIGTABLE_MIN_MEMORY = 128
LITTLE_BIGTABLE_MAX_MEMORY = 2048

# The min/max CPU/memory that the indexer can use
INDEXER_MIN_CPU = 100
INDEXER_MAX_CPU = 1000
INDEXER_MIN_MEMORY = 1024
INDEXER_MAX_MEMORY = 2048

# The min/max CPU/memory that the init can use
INIT_MIN_CPU = 10
INIT_MAX_CPU = 100
INIT_MIN_MEMORY = 32
INIT_MAX_MEMORY = 128

# The min/max CPU/memory that the eth1indexer can use
ETH1INDEXER_MIN_CPU = 100
ETH1INDEXER_MAX_CPU = 1000
ETH1INDEXER_MIN_MEMORY = 128
ETH1INDEXER_MAX_MEMORY = 1024

# The min/max CPU/memory that the rewards-exporter can use
REWARDSEXPORTER_MIN_CPU = 10
REWARDSEXPORTER_MAX_CPU = 100
REWARDSEXPORTER_MIN_MEMORY = 32
REWARDSEXPORTER_MAX_MEMORY = 128

# The min/max CPU/memory that the statistics can use
STATISTICS_MIN_CPU = 10
STATISTICS_MAX_CPU = 100
STATISTICS_MIN_MEMORY = 32
STATISTICS_MAX_MEMORY = 128

# The min/max CPU/memory that the frontend-data-updater can use
FDU_MIN_CPU = 10
FDU_MAX_CPU = 100
FDU_MIN_MEMORY = 32
FDU_MAX_MEMORY = 128

# The min/max CPU/memory that the frontend can use
FRONTEND_MIN_CPU = 100
FRONTEND_MAX_CPU = 1000
FRONTEND_MIN_MEMORY = 512
FRONTEND_MAX_MEMORY = 2048


def launch_full_beacon(
    plan,
    config_template,
    cl_client_contexts,
    el_client_contexts,
):
    postgres_output = postgres.run(
        plan,
        service_name="beaconchain-postgres",
        image="postgres:15.2-alpine",
        user=POSTGRES_USER,
        password=POSTGRES_PASSWORD,
        database=POSTGRES_DB,
        min_cpu=POSTGRES_MIN_CPU,
        max_cpu=POSTGRES_MAX_CPU,
        min_memory=POSTGRES_MIN_MEMORY,
        max_memory=POSTGRES_MAX_MEMORY,
        persistent=False,
    )
    redis_output = redis.run(
        plan,
        service_name="beaconchain-redis",
        image="redis:7",
        min_cpu=REDIS_MIN_CPU,
        max_cpu=REDIS_MAX_CPU,
        min_memory=REDIS_MIN_MEMORY,
        max_memory=REDIS_MAX_MEMORY,
    )
    # TODO perhaps create a new service for the littlebigtable
    little_bigtable = plan.add_service(
        name="beaconchain-littlebigtable",
        config=ServiceConfig(
            image="gobitfly/little_bigtable:latest",
            ports={
                LITTLE_BIGTABLE_PORT_ID: PortSpec(
                    LITTLE_BIGTABLE_PORT_NUMBER, application_protocol="tcp"
                )
            },
            min_cpu=LITTLE_BIGTABLE_MIN_CPU,
            max_cpu=LITTLE_BIGTABLE_MAX_CPU,
            min_memory=LITTLE_BIGTABLE_MIN_MEMORY,
            max_memory=LITTLE_BIGTABLE_MAX_MEMORY,
        ),
    )

    el_uri = "http://{0}:{1}".format(
        el_client_contexts[0].ip_addr, el_client_contexts[0].rpc_port_num
    )
    redis_url = "{}:{}".format(redis_output.hostname, redis_output.port_number)

    template_data = new_config_template_data(
        cl_client_contexts[0],
        el_uri,
        little_bigtable.ip_address,
        LITTLE_BIGTABLE_PORT_NUMBER,
        postgres_output.url,
        POSTGRES_PORT_NUMBER,
        redis_url,
        FRONTEND_PORT_NUMBER,
    )

    template_and_data = shared_utils.new_template_and_data(
        config_template, template_data
    )
    template_and_data_by_rel_dest_filepath = {}
    template_and_data_by_rel_dest_filepath[
        FULL_BEACONCHAIN_CONFIG_FILENAME
    ] = template_and_data

    config_files_artifact_name = plan.render_templates(
        template_and_data_by_rel_dest_filepath, "config.yml"
    )

    # Initialize the db schema
    initdbschema = plan.add_service(
        name="beaconchain-schema-initializer",
        config=ServiceConfig(
            image=IMAGE_NAME,
            files={
                "/app/config/": config_files_artifact_name,
            },
            entrypoint=["tail", "-f", "/dev/null"],
            min_cpu=INIT_MIN_CPU,
            max_cpu=INIT_MAX_CPU,
            min_memory=INIT_MIN_MEMORY,
            max_memory=INIT_MAX_MEMORY,
        ),
    )

    plan.print("applying db schema")
    plan.exec(
        service_name=initdbschema.name,
        recipe=ExecRecipe(
            ["./misc", "-config", "/app/config/config.yml", "-command", "applyDbSchema"]
        ),
    )

    plan.print("applying big table schema")
    # Initialize the bigtable schema
    plan.exec(
        service_name=initdbschema.name,
        recipe=ExecRecipe(
            [
                "./misc",
                "-config",
                "/app/config/config.yml",
                "-command",
                "initBigtableSchema",
            ]
        ),
    )

    # Start the indexer
    indexer = plan.add_service(
        name="beaconchain-indexer",
        config=ServiceConfig(
            image=IMAGE_NAME,
            files={
                "/app/config/": config_files_artifact_name,
            },
            entrypoint=["./explorer"],
            cmd=[
                "-config",
                "/app/config/config.yml",
            ],
            env_vars={
                "INDEXER_ENABLED": "TRUE",
            },
            min_cpu=INDEXER_MIN_CPU,
            max_cpu=INDEXER_MAX_CPU,
            min_memory=INDEXER_MIN_MEMORY,
            max_memory=INDEXER_MAX_MEMORY,
        ),
    )
    # Start the eth1indexer
    eth1indexer = plan.add_service(
        name="beaconchain-eth1indexer",
        config=ServiceConfig(
            image=IMAGE_NAME,
            files={
                "/app/config/": config_files_artifact_name,
            },
            entrypoint=["./eth1indexer"],
            cmd=[
                "-config",
                "/app/config/config.yml",
                "-blocks.concurrency",
                "1",
                "-blocks.tracemode",
                "geth",
                "-data.concurrency",
                "1",
                "-balances.enabled",
            ],
            min_cpu=ETH1INDEXER_MIN_CPU,
            max_cpu=ETH1INDEXER_MAX_CPU,
            min_memory=ETH1INDEXER_MIN_MEMORY,
            max_memory=ETH1INDEXER_MAX_MEMORY,
        ),
    )

    rewardsexporter = plan.add_service(
        name="beaconchain-rewardsexporter",
        config=ServiceConfig(
            image=IMAGE_NAME,
            files={
                "/app/config/": config_files_artifact_name,
            },
            entrypoint=["./rewards-exporter"],
            cmd=[
                "-config",
                "/app/config/config.yml",
            ],
            min_cpu=REWARDSEXPORTER_MIN_CPU,
            max_cpu=REWARDSEXPORTER_MAX_CPU,
            min_memory=REWARDSEXPORTER_MIN_MEMORY,
            max_memory=REWARDSEXPORTER_MAX_MEMORY,
        ),
    )

    statistics = plan.add_service(
        name="beaconchain-statistics",
        config=ServiceConfig(
            image=IMAGE_NAME,
            files={
                "/app/config/": config_files_artifact_name,
            },
            entrypoint=["./statistics"],
            cmd=[
                "-config",
                "/app/config/config.yml",
                "-charts.enabled",
                "-graffiti.enabled",
                "-validators.enabled",
            ],
            min_cpu=STATISTICS_MIN_CPU,
            max_cpu=STATISTICS_MAX_CPU,
            min_memory=STATISTICS_MIN_MEMORY,
            max_memory=STATISTICS_MAX_MEMORY,
        ),
    )

    fdu = plan.add_service(
        name="beaconchain-fdu",
        config=ServiceConfig(
            image=IMAGE_NAME,
            files={
                "/app/config/": config_files_artifact_name,
            },
            entrypoint=["./frontend-data-updater"],
            cmd=[
                "-config",
                "/app/config/config.yml",
            ],
            min_cpu=FDU_MIN_CPU,
            max_cpu=FDU_MAX_CPU,
            min_memory=FDU_MIN_MEMORY,
            max_memory=FDU_MAX_MEMORY,
        ),
    )

    frontend = plan.add_service(
        name="beaconchain-frontend",
        config=ServiceConfig(
            image=IMAGE_NAME,
            files={
                "/app/config/": config_files_artifact_name,
            },
            entrypoint=["./explorer"],
            cmd=[
                "-config",
                "/app/config/config.yml",
            ],
            env_vars={
                "FRONTEND_ENABLED": "TRUE",
            },
            ports={
                FRONTEND_PORT_ID: PortSpec(
                    FRONTEND_PORT_NUMBER, application_protocol="http"
                ),
            },
            min_cpu=FRONTEND_MIN_CPU,
            max_cpu=FRONTEND_MAX_CPU,
            min_memory=FRONTEND_MIN_MEMORY,
            max_memory=FRONTEND_MAX_MEMORY,
        ),
    )


def new_config_template_data(
    cl_node_info, el_uri, lbt_host, lbt_port, db_host, db_port, redis_url, frontend_port
):
    return {
        "CLNodeHost": cl_node_info.ip_addr,
        "CLNodePort": cl_node_info.http_port_num,
        "ELNodeEndpoint": el_uri,
        "LBTHost": lbt_host,
        "LBTPort": lbt_port,
        "DBHost": db_host,
        "DBPort": db_port,
        "RedisEndpoint": redis_url,
        "FrontendPort": frontend_port,
    }


def new_cl_client_info(ip_addr, port_num, service_name):
    return {"IPAddr": ip_addr, "PortNum": port_num, "Name": service_name}
