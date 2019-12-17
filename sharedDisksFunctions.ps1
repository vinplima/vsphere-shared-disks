# function createSharedFlatHardDisk
#
# Cria disco compartilhado entre duas máquinas virtuais. O disco criado é do tipo Flat.
#
# Params
# * String $vm1Name nome da primeira VM (owner do disco)
# * String $vm2Name nome da segunda VM
# * Integer $capacityGB capacidade do disco a ser criado
function createSharedFlatHardDisk {
  param (
    $vm1Name,
    $vm2Name,
    $capacityGB
  )

  Get-VM @($vm1Name,$vm2Name) | ForEach-Object {

    if ($_.PowerState -eq 'PoweredOn') {

      shutdownVmGuestSync -vmName $_.Name
    }
  }

  # verifica se jah tem SCSI Controller disponivel
  $counter=@{'SCSI Controller 1'= 0; 'SCSI Controller 2' = 0; 'SCSI Controller 3' = 0}
  $scsiControllerToUse=$false
  $newSharedHardDisk=$false

  Get-VM $vm1Name | Get-HardDisk | ForEach-Object {

    $scsiController=$_ | Get-ScsiController

    if($scsiController.BusSharingMode -eq 'Physical') {

      $counter[$scsiController.Name]++
    }
  }

  @('SCSI Controller 1', 'SCSI Controller 2', 'SCSI Controller 3') | ForEach-Object {

    if ($counter[$_] -lt 15 -and $counter[$_] -gt 0 -and ! $scsiControllerToUse) {
      $scsiControllerToUse="$_"
    }
  }

  # se tiver a SCSI Controller, basta utiliza-la
  if($scsiControllerToUse) {

    $newSharedHardDisk=New-HardDisk -VM $vm1Name -CapacityGB $capacityGB -StorageFormat EagerZeroedThick -Controller $scsiControllerToUse
  }
  else {

    # cria o hard disk a ser compartilhado na vm1 (discos compartilhados deverao ser EagerZeroedThick) e coloca em uma ScsiController em modo de compartilhamento de Bus
    $newSharedHardDisk=New-HardDisk -vm $vm1Name -CapacityGB $capacityGB -StorageFormat EagerZeroedThick
    $fileName=$newSharedHardDisk.Filename

    # coloca o novo disco em uma controladora que possa compartilhar discos
    $newSharedHardDisk | New-ScsiController -Type ParaVirtual -BusSharingMode Physical
  
    # o objeto de disco foi realocado e eh preciso recupera-lo novamente
    $newSharedHardDisk= Get-VM $vm1Name | Get-HardDisk | Where-Object {$_.Filename -eq $fileName}
  }

  # coloca o disco em modo multi-writer (obrigatorio e compativel somente com vSphere 6)
  allowVmDiskMultiWriter -vmName $vm1Name -hardDiskName $newSharedHardDisk.Name

  # compartilha o disco com a vm 2 
  addSharedHardDisk -vmName $vm2Name -Filename $newSharedHardDisk.Filename -Controller $($newSharedHardDisk | Get-ScsiController).Name
}

# function shutdownVmGuestSync
#
# Desliga a VM pelo guest de modo síncrono. Essa opção não está implementada por padrão.
#
# Params
# * String $vmName nome da VM a ser desligada
function shutdownVmGuestSync {
  param(
    $vmName
  )

  Get-VM $vmName | Shutdown-VMGuest -Confirm:$false

  while ($(Get-VM $vmName).PowerState -eq 'PoweredOn') {
    Start-Sleep 10
  }
}

# function allowVmDiskMultiWriter 
#
# Ativa o MultiWriter no disco virtual.
# 
# Adaptado de https://github.com/lamw/vghetto-scripts/blob/master/powershell/configureMultiwriterVMDKFlag.ps1
#
# Params:
# * String $vmName nome da VM dona do disco
# * String $hardDiskName path do hard disk
function allowVmDiskMultiWriter {
  param(
    $vmName,      # nome da VM
    $hardDiskName # nome do HardDisk
  )

  # Retrieve VM and only its Devices
  $vmView = Get-View -ViewType VirtualMachine -Property Name,Config.Hardware.Device -Filter @{"Name" = $vmName}

  # Array of Devices on VM
  $vmDevices = $vmView.Config.Hardware.Device

  # Find the Virtual Disk that we care about
  foreach ($device in $vmDevices) {
      
      if($device -is  [VMware.Vim.VirtualDisk] -and $device.deviceInfo.Label -eq $hardDiskName) {
          $diskDevice = $device
      $diskDeviceBacking = $device.backing
      break
    }
  }

  # Create VM Config Spec to Edit existing VMDK & Enable Multi-Writer Flag
  $spec = New-Object VMware.Vim.VirtualMachineConfigSpec
  $spec.deviceChange = New-Object VMware.Vim.VirtualDeviceConfigSpec
  $spec.deviceChange[0].operation = 'edit'
  $spec.deviceChange[0].device = New-Object VMware.Vim.VirtualDisk
  $spec.deviceChange[0].device = $diskDevice
  $spec.DeviceChange[0].device.backing = $diskDeviceBacking
  $spec.DeviceChange[0].device.Backing.Sharing = "sharingMultiWriter"

  Write-Host "`nEnabling Multiwriter flag on on VMDK:" $hardDiskName "for VM:" $vmName
  $task = $vmView.ReconfigVM_Task($spec)
  $task1 = Get-Task -Id ("Task-$($task.value)")
  $task1 | Wait-Task
}

# function addSharedHardDisk
#
# Adiciona HD de uma VM em outra VM.
# 
# Params
# * String $vmName nome da VM
# * String $filename path do Harddisk a ser adicionado
# * String $controller nome da controladora a ser utilizada
# * Boolean $isRdm se o disco é RDM
function addSharedHardDisk {
  param(
    $vmName,
    $filename,
    $controller,
    $isRdm=$false
  )

  # logica de criacao de controller, se nao existir
  $scsiController=$false
  $dummyDiskFilename=$false

  while(!$scsiController) {

    $scsiController=Get-VM $vmName | Get-ScsiController | Where-Object {$_.Name -eq $controller}

    if(!$scsiController) {

      Write-Host "`nCria o SCSI Controller: "$controller

      $dummyDisk=New-HardDisk -vm $vmName -CapacityGB 1 -StorageFormat Thin
      $dummyDiskFilename=$dummyDisk.Filename
      $dummyDisk | New-ScsiController -Type ParaVirtual -BusSharingMode Physical
    }
  }
  
  # logica de compartilhamento de disco
  $dsName = $filename.Split(']')[0].TrimStart('[')
  
  $vm = (Get-VM $vmName).ExtensionData
  $ds = (Get-Datastore -Name $dsName).ExtensionData
  
  foreach($dev in $vm.config.hardware.device){

    if ($dev.deviceInfo.label -eq $controller){

      $CntrlKey = $dev.key
    }
  }
  
  $DevKey = 0

  # slots disponiveis em um scsi controller
  [System.Collections.ArrayList]$availableScsiSlots=@(0,1,2,3,4,5,6,8,9,10,11,12,13,14,15)

  foreach($dev in $vm.config.hardware.device) {

    if ($dev.controllerKey -eq $CntrlKey) {

      if ($dev.key -gt $DevKey) {$DevKey = $dev.key}
      $availableScsiSlots.Remove($dev.Unitnumber) # remove a unit que jah estiver ocupada
    }
  }

  # pega o primeiro slot disponivel no scsi controller
  $Unitnumber=$availableScsiSlots[0]

  $spec = New-Object VMware.Vim.VirtualMachineConfigSpec
  $spec.deviceChange = @()
  $spec.deviceChange += New-Object VMware.Vim.VirtualDeviceConfigSpec
  $spec.deviceChange[0].device = New-Object VMware.Vim.VirtualDisk

  if($isRdm) {

    $spec.deviceChange[0].device.backing = New-Object VMware.Vim.VirtualDiskRawDiskMappingVer1BackingInfo
  }
  else {

    $spec.deviceChange[0].device.backing = New-Object VMware.Vim.VirtualDiskFlatVer2BackingInfo
  }
  
  $spec.deviceChange[0].device.backing.datastore = $ds.MoRef
  $spec.deviceChange[0].device.backing.fileName = $filename
  $spec.deviceChange[0].device.backing.diskMode = "independent_persistent"
  $spec.deviceChange[0].device.key = $DevKey + 1

  $spec.deviceChange[0].device.unitnumber = $Unitnumber
  $spec.deviceChange[0].device.controllerKey = $CntrlKey
  $spec.deviceChange[0].operation = "add"
  
  Write-Host "`nSharing vmdk " $filename "for VM:" $vmName
  $task = $vm.ReconfigVM_Task($spec)
  $task1 = Get-Task -Id ("Task-$($task.value)")
  $task1 | Wait-Task

  # se o dummydisk tiver sido criado, ele devera ser removido
  if($dummyDiskFilename) {
    Write-Host "`nRemove o dummy disk: "$dummyDiskFilename
    Get-VM $vmName | Get-HardDisk | Where-Object {$_.Filename -eq $dummyDiskFilename} | Remove-HardDisk -DeletePermanently -Confirm:$False
  }
}

# function createSharedRdmDisk
#
# Cria discos RDM compartilhados.
#
# Params
# String $wwnFileName path do arquivo com o wwn dos devices a serem adicionados como RDM
# String $vm1Name nome da primeira VM
# String $vm2Name nome da segunda VM
function createSharedRdmDisk {
    param(
      $wwnFileName, # arquivo com o wwn dos devices a serem adicionados como RDM
      $vm1Name,     # nome da primeira VM
      $vm2Name      # nome da segunda VM
    )

  $activeScsiController=$false
  $scsiControllerDisksCount=0
  $scsiControllerDisksLimit=15
  $diskType="RawPhysical"

  if(!$activeScsiController) {

    # recuperar controladora compartilhada existente
    $activeScsiController=Get-VM $vm1Name | Get-ScsiController | Where-Object {$_.BusSharingMode -eq "Physical"} | Select-Object -First 1 

    if($activeScsiController) {

      Get-VM $vm1Name | Get-HardDisk | ForEach-Object {
        if($_ | Get-ScsiController | Where-Object {$_.Name -eq $activeScsiController.Name}) {
          $scsiControllerDisksCount++;
        }
      }  
    }
  }

  # abrir o arquivo texto e iterar entre cada um dos WWNs
  Get-Content $wwnFileName | ForEach-Object {
    $wwn=$_

    if ($activeScsiController) {

      New-HardDisk -VM $vm1Name -DiskType $diskType -DeviceName /vmfs/devices/disks/naa.$wwn -Controller $activeScsiController
    }   
    else {

      $activeScsiController=New-HardDisk -VM $vm1Name -DiskType $diskType -DeviceName /vmfs/devices/disks/naa.$wwn | New-ScsiController -Type ParaVirtual -BusSharingMode Physical
    }
    
    $scsiControllerDisksCount++;

    if($scsiControllerDisksCount -eq $scsiControllerDisksLimit) {

      $activeScsiController=$false
      $scsiControllerDisksCount=0
    }
  }

  # compartilhar os discos com a segunda maquina virtual
  Get-VM $vm1Name | Get-HardDisk | Where-Object {$_.DiskType -eq $diskType} | ForEach-Object {
    $scsi_controller=Get-ScsiController -HardDisk $_ 
    addSharedHardDisk -vmName $vm2Name -Filename $_.Filename -Controller $scsi_controller.Name -isRdm $true
  }
}