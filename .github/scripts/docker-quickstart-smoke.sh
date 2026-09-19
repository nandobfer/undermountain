#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
DOCKER_DIR="${REPO_ROOT}/docker"
ENV_FILE="${DOCKER_DIR}/.env"
CONFIG_FILE="$(mktemp)"

export COMPOSE_PROJECT_NAME="${COMPOSE_PROJECT_NAME:-otbr-smoke}"
CANARY_PROFILE="${CANARY_PROFILE:-dev}"
CANARY_BUILDER="${CANARY_BUILDER:-default}"
export COMPOSE_PROFILES="${CANARY_PROFILE}"

case "${CANARY_PROFILE}" in
	dev)
		SERVER_SERVICE="server"
		MYAAC_SERVICE="myaac"
		;;
	prod)
		SERVER_SERVICE="server-prod"
		MYAAC_SERVICE="myaac-prod"
		;;
	*)
		echo "Unsupported CANARY_PROFILE: ${CANARY_PROFILE}" >&2
		exit 1
		;;
esac

cd "${DOCKER_DIR}"
cp .env.dist "${ENV_FILE}"
cp "${REPO_ROOT}/config.lua.dist" "${CONFIG_FILE}"
export CANARY_CONFIG_FILE="${CONFIG_FILE}"

if [[ -n "${CANARY_IMAGE:-}" ]]; then
	sed -i "s|^CANARY_IMAGE=.*|CANARY_IMAGE=${CANARY_IMAGE}|" "${ENV_FILE}"
fi

if [[ -n "${CANARY_IMAGE_TAR:-}" ]]; then
	docker load --input "${REPO_ROOT}/${CANARY_IMAGE_TAR}"
fi

COMPOSE=(docker compose --profile "${CANARY_PROFILE}" --env-file "${ENV_FILE}")

dump_debug() {
	echo "::group::Docker compose status"
	"${COMPOSE[@]}" ps || true
	echo "::endgroup::"

	echo "::group::Docker compose logs"
	"${COMPOSE[@]}" logs --no-color db "${SERVER_SERVICE}" "${MYAAC_SERVICE}" login-server || true
	echo "::endgroup::"
}

cleanup() {
	"${COMPOSE[@]}" down -v --remove-orphans || true
	rm -f "${CONFIG_FILE}"
}

on_exit() {
	local status=$?

	if [[ "${status}" -ne 0 ]]; then
		dump_debug
	fi

	cleanup
	exit "${status}"
}

wait_for_http_status() {
	local name="$1"
	local url="$2"
	local expected_status="$3"
	local body_file

	body_file="$(mktemp)"

	for attempt in $(seq 1 120); do
		local status
		status="$(curl -sS -o "${body_file}" -w "%{http_code}" "${url}" || true)"

		if [[ "${status}" == "${expected_status}" ]]; then
			echo "${name} returned HTTP ${expected_status}"
			rm -f "${body_file}"
			return 0
		fi

		echo "Waiting for ${name}: expected ${expected_status}, got ${status} (attempt ${attempt}/120)"
		sleep 5
	done

	echo "${name} did not return HTTP ${expected_status}" >&2
	cat "${body_file}" >&2 || true
	rm -f "${body_file}"
	return 1
}

wait_for_login_server() {
	local response_file

	response_file="$(mktemp)"

	for attempt in $(seq 1 60); do
		local status
		status="$(
			curl -sS -o "${response_file}" -w "%{http_code}" \
				-H "Content-Type: application/json" \
				-d '{"email":"@test1","password":"test","type":"login","clientversion":"1525"}' \
				http://localhost:8088/login || true
		)"

		if [[ "${status}" == "200" ]] &&
			grep -q '"worlds"' "${response_file}" &&
			grep -q 'Rook Noob 1' "${response_file}"; then
			echo "login-server returned the seeded test account"
			rm -f "${response_file}"
			return 0
		fi

		echo "Waiting for login-server: got HTTP ${status} (attempt ${attempt}/60)"
		sleep 5
	done

	echo "login-server did not return the seeded test account" >&2
	cat "${response_file}" >&2 || true
	rm -f "${response_file}"
	return 1
}

wait_for_server_online() {
	for attempt in $(seq 1 120); do
		if "${COMPOSE[@]}" logs --no-color "${SERVER_SERVICE}" 2>/dev/null | grep -q "Undermountain server online"; then
			echo "${SERVER_SERVICE} is online"
			return 0
		fi

		echo "Waiting for ${SERVER_SERVICE} (attempt ${attempt}/120)"
		sleep 5
	done

	echo "${SERVER_SERVICE} did not become online" >&2
	return 1
}

trap on_exit EXIT

cleanup

"${COMPOSE[@]}" config >/tmp/canary-docker-compose.yml
if [[ -n "${CANARY_IMAGE_TAR:-}" || "${CANARY_PROFILE}" == "prod" ]]; then
	"${COMPOSE[@]}" pull db login-server
else
	"${COMPOSE[@]}" pull db server login-server
fi
docker buildx inspect "${CANARY_BUILDER}" >/dev/null
"${COMPOSE[@]}" build --builder "${CANARY_BUILDER}"
"${COMPOSE[@]}" up -d --no-build

wait_for_server_online
wait_for_http_status "MyAAC home" "http://localhost:8080/" "200"
wait_for_http_status "MyAAC login.php" "http://localhost:8080/login.php" "404"

"${COMPOSE[@]}" exec -T "${MYAAC_SERVICE}" test ! -f /var/www/html/login.php

"${COMPOSE[@]}" exec -T "${SERVER_SERVICE}" sh -lc '
	grep -q "mysqlHost = \"db\"" config.lua &&
	grep -q "mysqlDatabase = \"canary\"" config.lua &&
	grep -q "loginProtocolPort = 7171" config.lua &&
	grep -q "gameProtocolPort = 7172" config.lua &&
	grep -q "statusProtocolPort = 7173" config.lua &&
	grep -q "dataPackDirectory = \"data-canary\"" config.lua &&
	grep -q "toggleDownloadMap = false" config.lua &&
	test -f data-canary/world/canary.otbm
'

mounts="$(docker inspect --format '{{range .Mounts}}{{printf "%s %s %t\n" .Destination .Type .RW}}{{end}}' "$("${COMPOSE[@]}" ps -q "${SERVER_SERVICE}")")"
if [[ "${CANARY_PROFILE}" == "dev" ]]; then
	grep -q '^/canary/data bind false$' <<<"${mounts}"
	grep -q '^/canary/data-canary bind false$' <<<"${mounts}"
	grep -q '^/host-config/config.lua bind false$' <<<"${mounts}"
	"${COMPOSE[@]}" exec -T "${SERVER_SERVICE}" sh -lc '
		if touch data/.mount-write-test 2>/dev/null; then
			rm -f data/.mount-write-test
			exit 1
		fi
		if touch data-canary/.mount-write-test 2>/dev/null; then
			rm -f data-canary/.mount-write-test
			exit 1
		fi
	'
else
	if grep -q ' bind ' <<<"${mounts}"; then
		echo "Production server unexpectedly contains a bind mount" >&2
		printf '%s\n' "${mounts}" >&2
		exit 1
	fi
	"${COMPOSE[@]}" exec -T "${SERVER_SERVICE}" test ! -e /canary/data-otservbr-global
fi

wait_for_login_server
