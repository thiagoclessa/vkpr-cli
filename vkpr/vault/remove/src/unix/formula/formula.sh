#!/bin/bash

runFormula() {
  $VKPR_HELM uninstall vault -n $VKPR_K8S_NAMESPACE
  $VKPR_KUBECTL delete ns vkpr
}
