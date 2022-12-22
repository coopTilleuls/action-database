# Local dev env

Rather than pushing every change to Github in order to trigger action, we try to replicate an local environment as close as possible to GH.

You must provide :
- a `./docker/data/kubeconfig` file containing credentials to connect to a (nonprod) cluster using an serviceaccount restricted to a namespace.
  - see internal "Logins SRE" where you can find one restricted to `nonprod-devsre` namespace.
- a `./.env.dev` file that you can create using the `./.env.dev.dist` template file

The mounted files `{mysql|postgresql}.sql.gz` contains an almost empty database `sql` file used to test import action.

Then you can execute `docker compose build` which will build the Docker images.

Finally run `docker compose run script` which runs by default the provided `./script.sh`.

You can also override a env var (e.g. use another action) using `docker compose run --env ACTION=delete script`
