#!/usr/bin/bash

set -e
cd "$(dirname "$0")"

if [ "$#" -ne 2 ]; then
  echo "Usage: publish_lw_win.sh <version> <setup_file_url>" >&2
  echo "           (for example: └ 97.0-2  └ https://gitlab.com/(...)-setup.exe)" >&2
  exit 1
fi

require_command() {
  if ! command -v "$1" >/dev/null; then
    echo "Error: '$1' is not installed but required for this script" >&2
    exit 1
  fi
}

require_command curl
require_command git
require_command jq
require_command docker

echo "publish_lw_win.sh"
echo

prompt_password() {
  unset password
  prompt="$1"
  while IFS= read -p "$prompt" -r -s -n 1 char; do
    if [[ $char == $'\0' ]]; then
      break
    fi
    prompt='*'
    password+="$char"
  done
  echo
}

localdir=~/.local/share/publish_lw_win
mkdir -p $localdir

# Set up choco API key
file_choco_api_key=$localdir/choco_api_key
if [ ! -f $file_choco_api_key ]; then
  prompt_password "Please enter your Chocolatey API key: "
  choco_api_key=$password
  echo $choco_api_key >$file_choco_api_key
  chmod 600 $file_choco_api_key
else
  choco_api_key=$(cat $file_choco_api_key)
fi

# Set up gh API key
file_gh_token=$localdir/gh_token
if [ ! -f $file_gh_token ]; then
  prompt_password "Please enter your GitHub token: "
  gh_token=$password
  echo $gh_token >$file_gh_token
  chmod 600 $file_gh_token
else
  gh_token=$(cat $file_gh_token)
fi

gh_request() {
  response="$(curl -s -H "Authorization: token $gh_token" -H "Accept: application/vnd.github.v3+json" "$@")"
  if [ "$(echo "$response" | jq 'type')" == "object" ]; then
    if [ "$(echo "$response" | jq 'has("message")')" == "true" ]; then
      echo "Error with GitHub API: $(echo "$response" | jq -r '.message')" >&2
      exit 1
    fi
    if [ "$(echo "$response" | jq 'has("errors")')" == "true" ]; then
      echo "Error(s) with GitHub API:" >&2
      echo "$pr_response" | jq -r '.errors | .[].message' >&2
      exit 1
    fi
  fi
  echo "$response"
}

export version="$(echo "$1" | sed 's/v//g')"
export file="$2"

echo
echo "-> Calculating checksum"
tmpdir=$(mktemp -d)
curl -Lo "$tmpdir/setup.exe" "$file"
export checksum=$(sha256sum "$tmpdir/setup.exe" | cut -d ' ' -f 1)
rm -rf "$tmpdir"
echo "Checksum (sha256) is $checksum"

echo
echo
echo "-> Building .nupkg"
ver=$(echo "$version" | sed 's/-.*$//g')
rel=$(echo "$version" | sed 's/^.*-//g')
export choco_version="$ver$(echo $(for i in $(seq $(echo "$ver" | tr -cd '.' | wc -c) 1); do printf ".0"; done)).$rel"
echo "v$version -> v$choco_version"
tmpdir=$(mktemp -d)
mkdir -p "$tmpdir/tools"
envsubst <choco/librewolf.nuspec.in >$tmpdir/librewolf.nuspec
envsubst <choco/tools/chocolateyinstall.ps1.in >$tmpdir/tools/chocolateyinstall.ps1
cp choco/tools/chocolateyuninstall.ps1 $tmpdir/tools
# If we are on windows we can use choco directly, else use a docker image
if command -v choco; then
  export choco="choco"
else
  export choco="docker run --rm -v $tmpdir:$tmpdir -w $tmpdir linuturk/mono-choco"
fi
(cd "$tmpdir" && $choco pack)

echo
echo
echo "-> Pushing .nupkg to Chocolatey"
(cd "$tmpdir" && $choco push librewolf.*.nupkg --source https://push.chocolatey.org/ -k $choco_api_key)
rm -rf "$tmpdir"

echo
echo
echo "-> Creating pull request for Winget"
username=$(gh_request "https://api.github.com/user" | jq -r .login)
if ! curl -sf -H "Authorization: token $gh_token" "https://api.github.com/repos/$username/winget-pkgs" >/dev/null; then
  printf "Forking microsoft/winget-pkgs...\r"
  gh_request -X POST "https://api.github.com/repos/microsoft/winget-pkgs/forks" >/dev/null
  echo "Forked microsoft/winget-pkgs to $username/winget-pkgs"
fi
clonedir=$localdir/winget-pkgs
if [ ! -d "$clonedir/.git" ]; then
  git clone https://github.com/$username/winget-pkgs.git "$clonedir"
  (
    cd "$clonedir"
    git remote add upstream https://github.com/microsoft/winget-pkgs.git
    git config user.name "LibreWolf"
    git config user.email "publish_lw_win@librewolf.net"
    git config commit.gpgSign "false"
  )
fi
(
  cd "$clonedir"
  git fetch upstream
  git switch -C update_librewolf
  git reset --hard upstream/master
)
wingetdir="$clonedir/manifests/l/LibreWolf/LibreWolf/$version"
mkdir "$wingetdir"
envsubst <winget/LibreWolf.LibreWolf.installer.yaml.in >$wingetdir/LibreWolf.LibreWolf.installer.yaml
envsubst <winget/LibreWolf.LibreWolf.locale.en-US.yaml.in >$wingetdir/LibreWolf.LibreWolf.locale.en-US.yaml
envsubst <winget/LibreWolf.LibreWolf.yaml.in >$wingetdir/LibreWolf.LibreWolf.yaml
(
  cd "$clonedir"
  git add .
  git commit -m "Update LibreWolf.LibreWolf to v$version"
  git remote set-url --push origin https://$username:$gh_token@github.com/$username/winget-pkgs.git
  git push origin update_librewolf --force
)
printf "Creating pull request...\r"
pr_response=$(gh_request "https://api.github.com/repos/microsoft/winget-pkgs/pulls" -d "{\"head\":\"$username:update_librewolf\",\"base\":\"master\",\"title\":\"Update LibreWolf.LibreWolf to v${version}\",\"body\":\"(This pull-request was auto-generated.)\"}")
echo "Pull request created: $(echo "$pr_response" | jq -r .html_url)"

echo
echo
echo "Done."
