setup() {
  load $VKPR_HOME/bats/bats-support/load.bash
  load $VKPR_HOME/bats/bats-assert/load.bash
}

setup_file() {
  load '../.bats/common.bats.bash'
  _common_setup

  if [ "$VKPR_TEST_SKIP_PROVISIONING" == "true" ]; then
    echo "setup: skipping provisionig due to VKPR_TEST_SKIP_PROVISIONING=true" >&3
  else
    echo "setup: installing kong..." >&3
    rit vkpr kong install --default
  fi
}

@test "Use vkpr.yaml to merge values in kong with helmArgs" {
  testValue="kong-test"
  useVKPRfile changeYAMLfile ".kong.helmArgs.fullnameOverride = \"${testValue}\" |
    .kong.helmArgs.admin.ingress.path = \"/test\"
  "
  sleep 10

  run $VKPR_HELM get values kong -n vkpr
  assert_line --partial "fullnameOverride: kong-test"
  assert_success
}

@test "Use vkpr.yaml to change values in kong with globals" {
  useVKPRfile changeYAMLfile ".global.namespace = \"vtg\" |
    .kong.namespace = \"vkpr\"
  "
  sleep 10

  run $VKPR_HELM ls -A -o=json | $VKPR_JQ -r '.[] | select(.name | contains("kong"))'

  refute_line --partial "\"namespace\":\"vtg\""
  assert_success
}

teardown_file() {
  if [ "$VKPR_TEST_SKIP_TEARDOWN" == "true" ]; then
    echo "teardown: skipping uninstall due to VKPR_TEST_SKIP_TEARDOWN=true" >&3
  else
    echo "teardown: uninstalling kong..." >&3
    rit vkpr kong remove
  fi

  _common_teardown
}

useVKPRfile() {
  cp vkpr.yaml vkpr.yaml.tmp
  "$@"
  mv vkpr.yaml.tmp vkpr.yaml
}

#PARAMETERS:
# $1 - YQ_VALUES
# $2 - FORMULA_FLAGS (Optional)
changeYAMLfile() {
  $VKPR_YQ eval -i "del(.kong)" vkpr.yaml
  $VKPR_YQ eval "${1}" vkpr.yaml > vkpr.yaml
  rit vkpr kong install $2 --default
}
