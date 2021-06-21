#!/bin/sh
DAT_VG='pgdata_vg'
 
DAT_LV='pgdata_lv'

DAT_MNT='/data'

WAL_VG='pgwal_vg'

WAL_LV='pgwal_lv'

WAL_MNT='/wal'

array=()
#collecting all lun numbers
lun=$(sudo dmesg | grep SCSI | grep 'Attached' | cut -d: -f 4,5 | cut -b 1,2 | tr -d ':')
#echo $lun
array+=($lun)

#elimnating the duplicates in array
array_ids=($(echo "${array[@]}" | tr ' ' '\n' | sort -u | tr '\n' ' '))
#echo ${array_ids[@]}
#echo $array
lundata=()

#iterate over lun data which is stored in arra_ids to reomve lun 0's
for i in ${array_ids[@]}
do
if [ $i == 0 ]
then
continue
fi
#echo $i
lundata+=($i)
done
lun_data=($(echo "${lundata[@]}" | tr ' ' '\n' | sort -u | tr '\n' ' '))

#soting the lun data to unique values
lun_data=( $( printf "%s\n" "${lun_data[@]}" | sort -n ) )
echo "The attached disks lun Numbers is ${lun_data[*]}"

#condition to check volume(WAL) is mounted else get the disk name example 'sde'
WAL_SDX=/dev/$(sudo dmesg | grep SCSI | grep 'Attached' | cut -d: -f 4,5 | grep ${lun_data[0]} | tail -n1 | cut -d'[' -f2 | cut -c 1-3)
if [ $(lsblk -l $WAL_SDX | grep -c pgwal_vg-pgwal_lv) == 1 ]
then
vg_size=$(sudo vgdisplay $WAL_VG | grep -Po "(?<=VG Size)[^,]*" | tr -d ' ')
echo "LVM group $WAL_VG for device ($WAL_SDX) of size ($vg_size) already exists"
else
echo "No lvm for wal device $WAL_SDX. Creating one...."
sudo pvcreate $WAL_SDX
sudo vgcreate $WAL_VG $WAL_SDX
sudo lvcreate -n $WAL_LV -l 100%FREE $WAL_VG
echo "LVM successfullt created for the device $(WAL_SDX)"
sudo mkfs.ext4 /dev/$WAL_VG/$WAL_LV
# create dirs and mounts
sudo mkdir $WAL_MNT
sudo chmod 666 /etc/fstab
echo "/dev/mapper/${WAL_VG}-${WAL_LV} $WAL_MNT ext4 noatime,defaults,nofail 1 2" >> /etc/fstab
sudo chmod 644 /etc/fstab
sudo mount $WAL_MNT
fi

#removing the first element in lun data
unset lun_data[0]
echo ${lun_data[*]}
MD_DEV=/dev/md0
datadisk1=()

#looping over lun data to get the disk names example '/dev/sde' to create RAID 0
for j in ${lun_data[*]};
do
DAT1_SDX=/dev/$(sudo dmesg | grep SCSI | grep 'Attached' | cut -d: -f 4,5 | grep $j | tail -n1 | cut -d'[' -f2 | cut -c 1-3)
DAT2_SDX=$(sudo dmesg | grep SCSI | grep 'Attached' | cut -d: -f 4,5 | grep $j | tail -n1 | cut -d'[' -f2 | cut -c 1-3)
#echo ${DAT1_SDX[*]}
datadisk1+=($DAT1_SDX)
newdisk+=($DAT2_SDX)
done
sorted_unique_ids=($(echo "${datadisk1[@]}" | tr ' ' '\n' | sort -u | tr '\n' ' '))
echo ${sorted_unique_ids[*]}


data_number=${#sorted_unique_ids[@]}
new_disk=()
exist_raid_disk=()
# check whether raid0 exists or not
if [ $(cat /proc/mdstat | grep -Po "(?<=md0 :)[^,]*" | grep -c 'active\|raid0') == 1 ];
then
echo "$(cat /proc/mdstat | grep -Po "(?<=md0 :)[^,]*") already exists"
#check any new device attached by looping over devices
for ls in ${!sorted_unique_ids[@]};
do
if [ $(lsblk -l ${sorted_unique_ids[$ls]} | grep -c md0) == 0 ];
then
echo "New Attached device detected ${sorted_unique_ids[$ls]}. Adding this to existing RAID"
#append the new disk vaules
new_disk+=(${sorted_unique_ids[$ls]})
#getting the disk number by calculating older no of disk + no of new disks
DAT_DISK_NEW_NUM=$(( ${#exist_raid_disk[*]} + ${#new_disk[*]} ))
#echo $DAT_DISK_NEW_NUM
#adding new disk to existing array by converting to raid4 and then to raid0
RB_MIN=100
RB_MAX=200000
sudo sysctl -w dev.raid.speed_limit_min=$RB_MIN
sudo sysctl -w dev.raid.speed_limit_max=$RB_MAX
sudo mdadm --grow --level 4 $MD_DEV
sudo mdadm --manage $MD_DEV --add ${new_disk[*]}
sudo mdadm --grow --level 0 --raid-devices=$DAT_DISK_NEW_NUM $MD_DEV
sleep 5
count=0
maxcount=3000
while [ $count -le $maxcount ]; 
do 
status=$(sudo mdadm --detail /dev/md0 | grep -Po -c "(?<=Reshape Status :)[^,]*");
status1=$(sudo mdadm --detail /dev/md0 | grep -Po "(?<=Reshape Status :)[^,]*");
echo "Waiting for RAID4 status to return to RAID0 ($count of $maxcount retiers) --status is: $status1"
if [ $status == 1 ]; 
then 
sleep 5; 
((count++)); 
else 
break;
fi;
done
if [ $status == 0 ];
then
echo "Successfully converted to RAID0 $(cat /proc/mdstat | grep -Po "(?<=md0 :)[^,]*")"
sleep 5
echo "extending the lvm"
sudo pvresize $MD_DEV
sudo lvextend -l +100%FREE /dev/mapper/${DAT_VG}-${DAT_LV}
sudo resize2fs /dev/mapper/${DAT_VG}-${DAT_LV}
fi
#printing devices if its already exits
else
echo " device already exits in te RAID0 (${sorted_unique_ids[$ls]})"
exist_raid_disk+=(${sorted_unique_ids[$ls]})
fi
done
#if there is no raid0 exist it creats new raid for all data devices
else
echo "RAID0 doesn't exist. creating one....."
sudo mdadm --create --verbose $MD_DEV --level=0 --raid-devices=$data_number ${sorted_unique_ids[*]}
echo "Creating LVM for RAID0 md0"
sudo pvcreate $MD_DEV
sudo vgcreate $DAT_VG $MD_DEV
sudo lvcreate -n $DAT_LV -l 100%FREE $DAT_VG
sudo mkfs.ext4 /dev/$DAT_VG/$DAT_LV
# create dirs and mounts
sudo mkdir $DAT_MNT
sudo chmod 666 /etc/fstab
echo "/dev/mapper/${DAT_VG}-${DAT_LV} $DAT_MNT ext4 noatime,defaults,nofail 1 2" >> /etc/fstab
sudo chmod 644 /etc/fstab
sudo mount $DAT_MNT
fi