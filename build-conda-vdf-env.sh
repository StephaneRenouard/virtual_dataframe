#!/usr/bin/env bash
set -e
# usage ./build-conda-env.sh -h
which mamba >/dev/null;
if [[ $? == 0 ]] ;
then
  CONDA=mamba
else
  CONDA=conda
fi

normal=$(tput sgr0)
bold=$(tput bold)

remove() {
  for mode in ${VDF_MODES[@]} ;
  do
    echo $CONDA env remove $REF-$mode || true
    $CONDA env remove $REF-$mode || true
    echo -e "Conda env $NAME-$mode removed"
    if [[ $mode == dask* ]] ; then
      $CONDA env remove $REF-$mode-local || true
      echo -e "Conda env $NAME-$mode-local removed"
    fi
  done

}

create() {
  for mode in ${VDF_MODES[@]}
  do
      echo -e "${bold}Create conda env $NAME-$mode...${normal}"
      $CONDA create -y -q $CHANNEL $REF-$mode virtual_dataframe-$mode
      CONDA_PREFIX=$_CONDA_PREFIX-$mode \
      $CONDA env config vars set VDF_MODE=$mode
      if [[ $mode == dask* ]] ; then
          echo -e "${bold}Create conda env $NAME-$mode-local...${normal}"
          $CONDA create -y -q $CHANNEL $REF-$mode-local virtual_dataframe-$mode
          CONDA_PREFIX=$CONDA_HOME/envs/$NAME-$mode-local \
          $CONDA env config vars set VDF_MODE=$mode-local
          CONDA_PREFIX=$CONDA_HOME/envs/$NAME-$mode-local \
          $CONDA env config vars set VDF_CLUSTER=dask://.local
          echo -e "${bold}Create conda env $NAME-$mode and $NAME-$mode-local done${normal}"
      else
          echo -e "${bold}Create conda env $NAME-$mode done${normal}"
      fi
  done

}
NAME=vdf
VDF_MODES=(all pandas modin cudf dask dask_modin dask_cudf)
normal=$(tput sgr0)
bold=$(tput bold)
CHANNEL=${CHANNEL:--c rapidsai -c nvidia -c conda-forge}

do_remove=false
if ! options=$(getopt -u -o p:c:n:h -l prefix,name,channel,remove,delete,help -- "$@")
then
    # something went wrong, getopt will put out an error message for us
    exit 1
fi
set -- $options
while [ $# -gt 0 ]
do
    case $1 in
    -n|--name) NAME="$2" ; shift ;;
    -p|--prefix) PREFIX="$2" ; shift ;;
    -c|--channel) _CHANNEL+=("-c $2") ; shift;;
    --remove|--delete) do_remove=true ;;
    -h|--help) echo "Usage: $(basename $0) [-p <PREFIX> | -n <NAME>] [-c <channel>*] [<modes>*]"; exit 0 ;;
    (--) shift; break;;
    (-*) echo "$0: error - unrecognized option $1" 1>&2; exit 1;;
    (*) break;;
    esac
    shift
done
shift $((OPTIND-1)) # remove parsed options and args from $@ list

[[ ! -z "$_CHANNEL" ]] && CHANNEL=${_CHANNEL[@]}

[[ $# != 0 ]] && VDF_MODES=($*)
[[ -z "$CHANNEL" ]] && CHANNEL=-c rapids -c nvidia -c conda-forge
if [[ "$PREFIX" == "" ]]; then
  REF="-n $NAME"
  _CONDA_PREFIX=$CONDA_PREFIX/envs/$NAME
else
  REF="-p $PREFIX"
  _CONDA_PREFIX=$PREFIX
fi


if [[ $do_remove == "true" ]] ;
then
  remove
else
  create
fi
