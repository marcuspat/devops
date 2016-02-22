#!/bin/bash -x

killall VBoxHeadless

sleep 5

LIST=`VBoxManage list vms | awk -F "{" '{print $2}' | sed s/}//`

for i in $LIST
do
VBoxManage unregistervm $i
done

vagrant global-status --prune
