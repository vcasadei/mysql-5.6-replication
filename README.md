# Primary/Secondary MySQL Replication for MySQL 5.6


## Setup

1. Run the following command to build the images
```bash
docker-compose build --no-cache
```

2. Finally, start the instances
```bash
docker-compose up --force-recreate
```

This should create and start the `primary ` and `secondary` instances of percona server on ports 3306 and 3307 respectivelly.

## Instace Details

- Both MySQL instances have default username `root` and password empty.
- To change any configuration, you should make changes to the *primary/primary.cnf* and *secondary/secondary.cnf)* config files.

## Tutorial

For more information on how to set this up, check out my [post](https://#) and [video](https://#).