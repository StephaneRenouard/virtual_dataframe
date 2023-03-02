#!/bin/bash
# shellcheck disable=SC2086

if [ "$1" == "--source-only" ]; then
  exit 0
fi

VERSION=5.5.0
BUILT_DATE=2023-02-08
TAG=latest
RELEASE_NAME='domino-admin-toolkit'
INSTALLER_NAME='toolkit-bootstrap'

check_root()
{
  if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: Please run as root NOT sudo"
    exit 1
  fi
}

get_image()
{
  # Image is explicitly specified in the command line
  [ -n "$IMAGE" ] && return

  DOCKER_REGISTRY=$1
  case "$DOCKER_REGISTRY" in
    quay.io*)
      IMAGE=quay.io/domino/cre
      ;;
    mirrors.domino.tech*)
      IMAGE=mirrors.domino.tech/domino/admin-toolkit
      IMAGE_PULLSECRET='domino-mirrors-repos'
      ;;
    *)
      echo "WARNING: Docker registry '$DOCKER_REGISTRY' is not supported, you need to copy the toolkit's docker image to this registry first."
      echo "Run this command from the host where you have both Internet and docker registry access:"
      echo "  ./toolkit.sh push $DOCKER_REGISTRY/$RELEASE_NAME"
      echo "Then run the toolkit where you have kubectl access:"
      echo "  ./toolkit.sh install --image $DOCKER_REGISTRY/$RELEASE_NAME"
      echo "  ./toolkit.sh pytest"
      echo "Now will try quay.io anyway."
      IMAGE=quay.io/domino/cre
      ;;
  esac
}

check_kubectl_working() {
  kubectl version &>/dev/null
  if [ $? -ne 0 ]; then
    echo "ERROR: kubectl is not configured. Please run this where you have kubectl set up."
    check_root
    exit 1
  fi

  echo "INFO: Kube context set to $(kubectl config current-context)"
}

check_docker_working() {
  docker version &>/dev/null
  if [ $? -ne 0 ]; then
    echo "ERROR: docker is not configured. Please run this where you have docker set up."
    check_root
    exit 1
  fi
}

get_platform_namespace() {
  PLATFORM_NAMESPACE=$(kubectl get ns -l domino-platform -o jsonpath="{.items[*].metadata.name}" 2> /dev/null)
  if [ $? -ne 0 ]; then
    echo "ERROR: Unable to get platform namespace"
    check_root
    exit 1
  fi

  if [ "$PLATFORM_NAMESPACE" == "" ]; then
    echo "It looks like you may be running admin toolkit against a Domino 3.x deployment. Only Domino 4.x+ is supported."
    exit 1
  fi

  echo "INFO: Platform namespace is $PLATFORM_NAMESPACE"
}

set_environment() {
  APP_PORT="${APP_PORT:-8888}"
  DAEMONSET_MODE="${DAEMONSET_MODE:-False}"
  DAEMONSET_PORT="${DAEMONSET_PORT:-5000}"
  NUCLEUS_IMAGE=$(kubectl -n "$PLATFORM_NAMESPACE" get deploy nucleus-frontend -o jsonpath="{.spec.template.spec.containers[?(@.name=='nucleus-frontend')].image}")
  DOCKER_REGISTRY=$(echo "$NUCLEUS_IMAGE" | cut -d/ -f1) # Get the part before the first /
  IMAGE_PULLSECRET='domino-quay-repos'
  INGRESS_ENABLED="${INGRESS_ENABLED:-true}"
  get_image "$DOCKER_REGISTRY"
}

check_toolkit_installed() {
  kubectl -n "$PLATFORM_NAMESPACE" get deploy "$RELEASE_NAME"  &>/dev/null
  if [ $? -ne 0 ]; then
    false
  else
    true
  fi
}

check_toolkit_running() {
  pod_name=$(get_pod_name "app.kubernetes.io/name=$RELEASE_NAME")
  if [ -z "$pod_name" ]; then
    false
  fi
  pod_status=$(get_pod_status "$pod_name")
  if [ "$pod_status" == "Running" ]; then
    true
  else
    false
  fi
}

assert_toolkit_running() {
  if ! check_toolkit_running ; then
    echo "ERROR: Admin toolkit is not running. Please start with"
    echo "  ./toolkit.sh start"
    exit 1
  fi
}

start_toolkit() {
  kubectl -n "$PLATFORM_NAMESPACE" scale deploy "$RELEASE_NAME" --replicas=1
}

stop_toolkit() {
  kubectl -n "$PLATFORM_NAMESPACE" scale deploy "$RELEASE_NAME" --replicas=0
}

generate_yaml()
{
  ACTION="${ACTION:-install}"
  read -r -d '' CHART_YAML <<-EOF
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: $INSTALLER_NAME
  labels:
    app.kubernetes.io/name: $INSTALLER_NAME
    app.kubernetes.io/instance: $INSTALLER_NAME
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: domino-$PLATFORM_NAMESPACE-$INSTALLER_NAME
  labels:
    app.kubernetes.io/name: $INSTALLER_NAME
    app.kubernetes.io/instance: $INSTALLER_NAME
subjects:
- kind: ServiceAccount
  name: $INSTALLER_NAME
  namespace: $PLATFORM_NAMESPACE
roleRef:
  kind: ClusterRole
  name: cluster-admin
  apiGroup: rbac.authorization.k8s.io
---
kind: Pod
apiVersion: v1
metadata:
  name: $INSTALLER_NAME
  labels:
    app.kubernetes.io/name: $INSTALLER_NAME
    app.kubernetes.io/instance: $INSTALLER_NAME
  annotations:
    sidecar.istio.io/inject: "false"
spec:
  serviceAccountName: $INSTALLER_NAME
  securityContext:
    fsGroup: 0
    runAsGroup: 0
    runAsNonRoot: false
    runAsUser: 0
  containers:
  - name: $INSTALLER_NAME
    image: $IMAGE:$TAG
    imagePullPolicy: Always
    command: [ "/bin/bash", "-c", "--" ]
    args: [ "/app/install.sh" ]
    volumeMounts:
      - name: podinfo
        mountPath: /etc/podinfo
    env:
      - name: DAEMONSET_MODE
        value: "$DAEMONSET_MODE"
      - name: DAEMONSET_PORT
        value: "$DAEMONSET_PORT"
      - name: APP_PORT
        value: "$APP_PORT"
      - name: IMAGE
        value: $IMAGE
      - name: TAG
        value: $TAG
      - name: IMAGE_PULLSECRET
        value: $IMAGE_PULLSECRET
      - name: PLATFORM_NAMESPACE
        value: $PLATFORM_NAMESPACE
      - name: RELEASE_NAME
        value: $RELEASE_NAME
      - name: ACTION
        value: $ACTION
      - name: INGRESS_ENABLED
        value: "$INGRESS_ENABLED"
  restartPolicy: "Never"
  imagePullSecrets:
    - name: $IMAGE_PULLSECRET
  volumes:
    # Used by bootstrap script to determine the k8s environment
    - name: podinfo
      downwardAPI:
        items:
          - path: "labels"
            fieldRef:
              fieldPath: metadata.labels

EOF
}

get_pod_name() {
  label_selector=$1
  pod_name=$(kubectl get pods -o=jsonpath='{.items[0].metadata.name}' -l $label_selector -n $PLATFORM_NAMESPACE 2>/dev/null)
  echo $pod_name
}

get_pod_status() {
  kubectl -n "$PLATFORM_NAMESPACE" get pod $1 -o jsonpath="{.status.phase}"
}

check_installer_status() {
  POD_STATUS=$(get_pod_status $INSTALLER_NAME)
  COUNTER=0
  while [ "$POD_STATUS" != "Succeeded" ] && [ $COUNTER -le 20 ]; do
    echo "INFO: Installer is still running, status: $POD_STATUS. Sleeping for 10 seconds"
    sleep 10
    POD_STATUS=$(get_pod_status $INSTALLER_NAME)
    if [ $? -ne 0 ] || [ "$POD_STATUS" = "Failed" ] || [ "$POD_STATUS" = "Unknown" ]; then
      echo "ERROR: Something went wrong installing toolkit"
      POD_NAME=$INSTALLER_NAME CONTAINER_NAME="$INSTALLER_NAME" get_logs
      echo "INFO: Check pod related events"
      kubectl get events -n "$PLATFORM_NAMESPACE" --field-selector involvedObject.name="$INSTALLER_NAME"
      exit 1
    fi
    (( COUNTER=COUNTER+1 ))
  done
}

create_and_run_installer()
{
  ACTION="install"
  generate_yaml
  echo ""
  echo "INFO: Installing $RELEASE_NAME"
  run_installer

  toolkit_pod_name=$(get_pod_name "app.kubernetes.io/name=domino-admin-toolkit")
  POD_STATUS=$(get_pod_status $toolkit_pod_name)
  COUNTER=0
  while [ "$POD_STATUS" != "Running" ] && [ $COUNTER -le 20 ]; do
    echo "INFO: Pod is not running yet, status: ${POD_STATUS}. Sleeping for 5 seconds..."
    sleep 5
    POD_STATUS=$(get_pod_status $toolkit_pod_name)
    if [ $? -ne 0 ]; then
      echo "Error getting pod status"
      exit 1;
    fi
    (( COUNTER=COUNTER+1 ))
  done
  POD_STATUS=$(get_pod_status $toolkit_pod_name)
  if [ $? -ne 0 ] || [ "$POD_STATUS" != "Running" ]; then
    echo "ERROR: Pod hasn't started, check related events:"
    kubectl get events -n "$PLATFORM_NAMESPACE" --field-selector involvedObject.name="$toolkit_pod_name"
    exit 1
  fi

  echo "Pod is $POD_STATUS ok!"
}

run_installer()
{
  echo "$CHART_YAML" | kubectl apply -n $PLATFORM_NAMESPACE -f - >/dev/null
  check_installer_status
  POD_NAME=$INSTALLER_NAME CONTAINER_NAME="$INSTALLER_NAME" get_logs
}

delete_installer() {
  kubectl delete po/$INSTALLER_NAME sa/$INSTALLER_NAME -n $PLATFORM_NAMESPACE --ignore-not-found=true
  kubectl delete clusterrolebinding/$INSTALLER_NAME --ignore-not-found=true
}

create_and_run_uninstaller() {
  # k8s env object can't be updated, so deleting and installing the installer with updated ACTION
  echo ""
  echo "INFO: Cleanup previously installed bootstrap if found"
  delete_installer
  ACTION="cleanup"
  generate_yaml
  echo ""
  echo "INFO: Uninstalling $RELEASE_NAME if installed"
  run_installer
  echo ""
  echo "INFO: Deleting uninstaller objects"
  delete_installer
}

run_test() {
  if [ $# -eq 0 ]; then
    exec_command=("python" "test_runner.py")
  else
    exec_command=("python" "test_runner.py" "$@")
  fi

  run_exec "${exec_command[@]}"
  if [ "$1" == "--local-only" ]; then
    toolkit_pod_name=$(get_pod_name "app.kubernetes.io/name=domino-admin-toolkit")
    # cp file out of container
    kubectl cp "$toolkit_pod_name":report.html ./report.html -n "$PLATFORM_NAMESPACE"
  fi
}

run_pytest() {
  if [ $# -eq 0 ]; then
    exec_command=("pytest" "--compact" "--color=no" "-m" "not sensitive")
  else
    exec_command=("pytest" "--compact" "--color=no" "$@")
  fi
  echo
  echo "Running tests:"
  run_exec "${exec_command[@]}"
}

run_exec() {
  if [ $# -eq 0 ]; then
    exec_command=("/bin/bash")
  else
    exec_command=("$@")
  fi
  toolkit_pod_name=$(get_pod_name "app.kubernetes.io/name=domino-admin-toolkit")
  set -x
  kubectl exec -ti "$toolkit_pod_name" -c "$RELEASE_NAME" -n "$PLATFORM_NAMESPACE" -- "${exec_command[@]}"
  set +x
}

get_logs() {
  # shellcheck disable=SC2153
  kubectl logs -f "$POD_NAME" -c "$CONTAINER_NAME" -n "$PLATFORM_NAMESPACE"
}

verlte() {
  [ "$1" = "$(echo -e "$1\n$2" | sort -V | head -n1)" ]
}

print_usage() {
  echo "Usage: toolkit.sh [command] [options]"
  echo
  echo "Run with no parameters to create resources and run the tests"
  echo
  echo "Commands:"
  echo "  install [options]  Install and start the admin toolkit"
  echo "  uninstall          Uninstall the admin toolkit, deleting all resources"
  echo "  start              Starts the admin toolkit if it is stopped"
  echo "  stop               Stops the admin toolkit if it is running"
  echo "  status             Shows whether admin toolkit is installed and running"
  echo "  test    [options]  Run tests with given options and upload html report to S3"
  echo "  pytest  [options]  Run pytest directly, see https://docs.pytest.org/en/7.1.x/how-to/usage.html"
  echo "  exec    [command]  Execute a command in the toolkit container (by default /bin/bash), useful for debugging"
  echo "  logs               Show toolkit container logs"
  echo "  get-password       Retrieve the admin toolkit UI username and password"
  echo "  help               Get this help message"
  echo
  echo '`install` command options:'
  echo "  ./toolkit.sh install --tag|-t tag              Run specific docker image tag of the admin toolkit"
  echo "  ./toolkit.sh install --daemonset               Enable daemonset functionality"
  echo "  ./toolkit.sh install --daemonset-port|-d port  Set the host port the daemonset listens on. Default is port 5000."
  echo "  ./toolkit.sh install --no-ingress              Disable ingress route to toolkit pod."
  echo
  echo '`test` command options:'
  echo "  ./toolkit.sh test --help                  Show help including choice of parameters"
  echo "  ./toolkit.sh test --log-cli-level DEBUG   Show extra debugging output"
  echo "  ./toolkit.sh test --local-only            Copy HTML file to host and do not send the report output to Domino's S3"
  echo
  echo '`pytest` command options:'
  echo "  ./toolkit.sh pytest checks/<check>.py      Execute a single check"
  echo "  ./toolkit.sh pytest --collect-only         List all available checks but don't run them"
  echo "  ./toolkit.sh pytest --log-cli-level=DEBUG  Show extra debugging output"
  echo
}

check_zero_options() {
  if [ "$#" -gt 0 ]; then
    echo "Warning: unrecognised options: $*"
  fi
}

parse_install_options() {
  unrecognised=()
  while [[ $# -gt 0 ]]; do
    key="$1"
    case $key in
      -t|--tag)
        if [ -z "$2" ]; then
          echo "Error: tag value is missing"
          exit 1
        fi
        TAG="$2"
        shift 2
        ;;
      -e|--env)
        if [ -z "$2" ]; then
          echo "Error: environment variable is missing"
          exit 1
        fi
        # shellcheck disable=SC2034
        ENV_VAR="$2"
        shift 2
        ;;
      --image)
        if [ -z "$2" ]; then
          echo "Error: image name is missing"
          exit 1
        fi
        IMAGE="$2"
        shift 2
        ;;
      -d|--daemonset-port)
        if [ -z "$2" ]; then
          echo "Error: daemonset port is missing"
          exit 1
        fi
        DAEMONSET_PORT="$2"
        shift 2
        ;;
      --daemonset)
        DAEMONSET_MODE="True"
        shift
        ;;
      --no-ingress)
        INGRESS_ENABLED="false"
        shift
        ;;
      *)
        unrecognised+=("$1")
        shift
        ;;
    esac
  done
  check_zero_options "${unrecognised[@]}"
}

check_for_updates() {
  echo "INFO: Checking for updates"
  curl -LIs https://toolkit.re.domino.tech:443/.toolkit_version | grep "HTTP/1.1 200 OK" | head -1 |grep 200 &> /dev/null
  if [ $? -ne 0 ]; then
    echo "WARNING: Unable to reach toolkit repo, will continue with the current version $VERSION"
    echo
  else
    curl -LsSo .toolkit_version https://toolkit.re.domino.tech:443/.toolkit_version
    REPO_VERSION=$(cat .toolkit_version)
    check_toolkit_version
  fi
  echo
}

check_toolkit_version() {
  if [ "$VERSION" != "$REPO_VERSION" ]; then
    echo "WARNING: An updated version of toolkit is available, We recommend to update to the latest version and run again."
    echo
    echo "Run:"
    echo
    echo "curl -LsSO https://toolkit.re.domino.tech/toolkit.sh && chmod a+x ./toolkit.sh"
    echo "./toolkit.sh"
    echo
  fi
}

# ==== Main ====

echo "toolkit.sh version: $VERSION, $BUILT_DATE"
echo

if [ "$VERSION" != "master" ]; then
  check_for_updates
fi

check_kubectl_working
get_platform_namespace

command="$1"
shift
if ! [[ "$command" =~ ^(install|push|status|help|--help|-h)$ ]] && ! check_toolkit_installed ; then
    echo "ERROR: Unable to find deployment $RELEASE_NAME. Admin toolkit does not appear to be installed. Please install first with"
    echo "  ./toolkit.sh install"
    exit 1
fi

case $command in
  help|--help|-h)
    print_usage
    ;;
  uninstall)
    check_zero_options "$@"
    set_environment
    create_and_run_uninstaller
    ;;
  install)
    parse_install_options "$@"
    set_environment
    create_and_run_installer
    ;;
  start)
    if check_toolkit_running ; then
      echo "INFO: Admin toolkit is already running."
      exit 0
    fi
    check_zero_options "$@"
    set_environment
    start_toolkit
    ;;
  stop)
    if ! check_toolkit_running ; then
      echo "INFO: Admin toolkit is already not running."
      exit 0
    fi
    check_zero_options "$@"
    set_environment
    stop_toolkit
    ;;
  status)
    check_zero_options "$@"
    set_environment
    if ! check_toolkit_installed ; then
      echo "INFO: Admin toolkit is not installed."
      exit 0
    fi
    echo "INFO: Admin toolkit is installed."
    if ! check_toolkit_running ; then
      echo "INFO: Admin toolkit is not running."
      exit 0
    fi
    echo "INFO: Admin toolkit is running."
    ;;
  test)
    assert_toolkit_running
    set_environment
    run_test "$@"
    if [ "$VERSION" != "master" ]; then
      check_for_updates
    fi
    ;;
  pytest)
    assert_toolkit_running
    set_environment
    run_pytest "$@"
    if [ "$VERSION" != "master" ]; then
      check_for_updates
    fi
    ;;
  exec)
    assert_toolkit_running
    set_environment
    run_exec "$@"
    ;;
  logs)
    check_zero_options "$@"
    assert_toolkit_running
    set_environment
    pod_name=$(get_pod_name "app.kubernetes.io/name=$RELEASE_NAME")
    POD_NAME=$pod_name CONTAINER_NAME="$RELEASE_NAME" get_logs
    ;;
  push)
    if [ -z "$1" ]; then
      echo "Error: target image is missing"
      exit 1
    fi
    TARGET_IMAGE="$1"
    check_docker_working
    set -x
    curl -O https://domino-admin-toolkit-files.s3.us-west-2.amazonaws.com/domino-admin-toolkit.tar.gz
    docker load < domino-admin-toolkit.tar.gz
    docker image tag quay.io/domino/cre:slim "$TARGET_IMAGE":v1-compatible
    docker image tag 
    docker image push "$TARGET_IMAGE":v1-compatible
    set +x
    ;;
  get-password)
    check_zero_options "$@"
    set_environment
    PASSWORD=$(kubectl get secret $RELEASE_NAME-http -n $PLATFORM_NAMESPACE -o jsonpath='{.data.webui-password}' | base64 -d 2>/dev/null)
    USERNAME=$(kubectl get secret $RELEASE_NAME-http -n $PLATFORM_NAMESPACE -o jsonpath='{.data.webui-login}' | base64 -d  2>/dev/null)
    echo
    echo "The Admin Toolkit UI username is $USERNAME and password is $PASSWORD"
    echo
    ;;
  "")
    assert_toolkit_running
    set_environment
    run_test
    ;;
  *)
    echo "Unknown command '$command'"
    echo
    print_usage
esac
