# Script sharedDisksFunctions.ps1
#
# Scripts de apoio a gestao de discos do vSphere.
#
# Autor: Vinicius Porto Lima (vinicius.lima@tst.jus.br)
#

# Constants
$SCSI_CONTROLLER_DISK_LIMIT=15       # limite de discos por scsi controller
$SCSI_CONTROLLER_VM_LIMIT=4          # limite de scsi controllers por VM
$RDM_SHARED_DISK_TYPE="RawPhysical"  # disk type para discos RDM compartilhados

<#
.SYNOPSIS
Cria disco compartilhado entre duas maquinas virtuais. O disco criado e do tipo Flat e Thick EagerZeroed.

.DESCRIPTION
Cria disco compartilhado entre duas maquinas virtuais. O disco criado e do tipo Flat.

.PARAMETER vm1Name
nome da VM onde o disco sera criado

.PARAMETER vm2Name
nome da VM com a qual o disco sera compartilhado

.PARAMETER capacityGB
tamanho do disco flat a ser criado e compartilhado

.EXAMPLE
CreateSharedFlatHardDisk -vm1Name vm1157 -vm2Name vm1158 -capacityGB 100
Cria disco Thick Eager Zeroed de 100 GB na vm1157 e compartilha com a vm1158

.NOTES

#>
function CreateSharedFlatHardDisk {
  param (
    $vm1Name,
    $vm2Name,
    $capacityGB
  )

  Get-VM @($vm1Name,$vm2Name) | ForEach-Object {

    if ($_.PowerState -eq 'PoweredOn') {

      ShutdownVmGuestSync -vmName $_.Name
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
  AllowVmDiskMultiWriter -vmName $vm1Name -hardDiskName $newSharedHardDisk.Name

  # compartilha o disco com a vm 2 
  AddSharedHardDisk -vmName $vm2Name -Filename $newSharedHardDisk.Filename -Controller $($newSharedHardDisk | Get-ScsiController).Name
}

<#
.SYNOPSIS
Desliga a VM pelo guest de modo sincrono.

.DESCRIPTION
Desliga a VM pelo guest de modo sincrono. Isso nao esta disponivel por padrao nos modulos VMware

.PARAMETER vmName
nome da VM

.EXAMPLE
ShutdownVmGuestSync -vmName vm1157
Desliga a vm1157 pelo SO de modo sincrono.

.NOTES

#>
function ShutdownVmGuestSync {
  param(
    $vmName
  )

  Get-VM $vmName | Shutdown-VMGuest -Confirm:$false

  while ($(Get-VM $vmName).PowerState -eq 'PoweredOn') {
    Start-Sleep 10
  }
}

<#
.SYNOPSIS
Ativa o MultiWriter no disco virtual

.DESCRIPTION
Ativa o MultiWriter no disco virtual. Esse modo permite que o disco seja compartilhado com outra VM.
Adaptado de https://github.com/lamw/vghetto-scripts/blob/master/powershell/configureMultiwriterVMDKFlag.ps1

.PARAMETER vmName
nome da VM

.PARAMETER hardDiskName
nome do disco onde o modo multiwriter vai ser ativado.

.EXAMPLE
AllowVmDiskMultiWriter -vmName vm1157 -hardDiskName $(Get-VM vm1157 | Get-HardDisk | Where-Object {$_.Filename -like '*_2.vmdk'}).Filename
Ativa o modo multiwriter do disco vm1157_2.vmdk

.NOTES

#>
function AllowVmDiskMultiWriter {
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

<#
.SYNOPSIS
Adiciona HD de uma VM em outra VM.

.DESCRIPTION
Adiciona HD de uma VM em outra VM. Para tanto, a controladora SCSI deve ser compartilhada.

.PARAMETER vmName
nome da VM onde o disco sera adicionado

.PARAMETER filename
path do hard disk a ser adicionado (filename do objeto HardDisk)

.PARAMETER controller
nome da controladora onde o disco deve ser adicionado (sera criada, caso nao exista)

.PARAMETER isRdm
se o disco e ou nao e RDM

.EXAMPLE
AddSharedHardDisk -vmName vm1158 -filename $(Get-VM vm1157 | Get-HardDisk | Where-Object {$_.Filename -like '*_18.vmdk'}).Filename -controller "SCSI Controller 1" -isRdm:$true
Adiciona o disco RDM vm1157_18.vmdk na controladora SCSI Controller 1 da VM vm1158

.NOTES

#>
function AddSharedHardDisk {
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

<#
.SYNOPSIS
Cria discos RDM compartilhados entre duas VMs

.DESCRIPTION
Cria discos RDM compartilhados a partir de um arquivo com wwns, 1 por linha.
Os discos são adicionados primeiramente na vm1, e depois são apontados tambem
para a vm2.

.PARAMETER wwnFileName
Path para arquivo txt com um wwn por linha

.PARAMETER vm1Name
nome da VM onde os discos serao criados

.PARAMETER vm2Name
nome da VM com a qual os discos serao compartilhados

.EXAMPLE
CreateSharedRdmDisk -wwnFileName .\wwns.txt -vm1Name vm1157 -vm2Name vm1158

.NOTES

#>
function CreateSharedRdmDisk {
  param(
    $wwnFileName, # arquivo com o wwn dos devices a serem adicionados como RDM
    $vm1Name,     # nome da primeira VM
    $vm2Name      # nome da segunda VM
  )

  if ($(Get-Content $wwnFileName | Measure-Object).Count -gt $(GetVmAvailableSharedDisksSlots -vmName $vm1Name)) {

    throw 'There is not enough available disk slots for this operation'
  }

  CreateSharedRdmDiskVm1 -vm1Name $vm1Name -wwnFileName $wwnFileName
  CreateSharedRdmDiskVm2 -vm1Name $vm1Name -vm2Name $vm2Name -wwnFileName $wwnFileName
}

<#
.SYNOPSIS
Retorna o total de slots disponiveis para criacao de discos compartilhados

.DESCRIPTION
Retorna o total de slots disponiveis para a criação de discos. Considera espacos
disponiveis em controladoras compartilhadas e a possibilidade de se criar mais
controladoras compartilhadas.

.PARAMETER vmName
nome da VM

.EXAMPLE
GetVmAvailableSharedDisksSlots -vmName
Retorna o montante de slots de discos compartilhados disponíveis na VM

.NOTES

#>
function GetVmAvailableSharedDisksSlots {
  param(
    $vmName
  )

  $qntControllers=$(Get-VM $vmName | Get-ScsiController | Measure-Object).Count
  $sharedControllers=Get-VM $vmName | Get-ScsiController | Where-Object {$_.BusSharingMode -eq "Physical"}

  $diskCount = 0

  foreach ($controller in $sharedControllers){

    $diskCount = $diskCount + $(GetScsiControllerDisksCount -vmName $vmName -scsiControllerName $controller.Name)
  }

  $availableScsiSlot=$SCSI_CONTROLLER_VM_LIMIT-$qntControllers
  $availableDiskSlots=(($($sharedControllers | Measure-Object).Count + $availableScsiSlot) * $SCSI_CONTROLLER_DISK_LIMIT) - $diskCount

  return $availableDiskSlots
}

<#
.SYNOPSIS
Cria discos RDM compartilhaveis em uma VM

.DESCRIPTION
A partir de um arquivo texto contendo um WWN por linha, cria discos RDM RawPhysical
compartilhaveis em uma determinada VM. Esses discos podem ser compartilhados com 
outras VMs em um outro momento.

.PARAMETER vm1Name
Nome da VM onde os discos serao adicionados

.PARAMETER wwnFileName
Path do arquivo texto com um WWN por linha

.EXAMPLE
CreateSharedRdmDiskVm1 -wwnFileName .\wwns.txt -vm1Name vm1157
Cria discos RDM compartilhaveis disponiveis nos WWNs do arquivo texto wwns.txt na VM vm1157

.NOTES

#>
function CreateSharedRdmDiskVm1 {
  param(
    $wwnFileName, # arquivo com o wwn dos devices a serem adicionados como RDM
    $vm1Name     # nome da primeira VM
  )

  $wwns = Get-Content $wwnFileName
  $activeScsiController = $false
  $diskCount = 0

  foreach($wwn in $wwns){

    # tenta recuperar uma controladora scsi, se nao tiver nenhuma ativa
    if (!$activeScsiController) {

      $activeScsiController = GetAvailableSharedScsiController -vmName $vm1Name
      
      # se nao tiver nenhuma controladora disponivel e o limite de controladoras jah tiver sido atingido, iniciar excecao
      if(!$activeScsiController -and $(Get-VM $vm1Name | Get-ScsiController | Measure-Object).Count -eq $SCSI_CONTROLLER_VM_LIMIT) {

        throw "Shared disks limit reached"
      }
      elseif ($activeScsiController) {

        $diskCount = GetScsiControllerDisksCount -vmName $vm1Name -scsiControllerName $activeScsiController.Name
      }
    }

    # se a controladora estiver ativa, adicionar o disco nela
    if ($activeScsiController) {

      New-HardDisk -VM $vm1Name -DiskType $RDM_SHARED_DISK_TYPE -DeviceName /vmfs/devices/disks/naa.$wwn -Controller $activeScsiController
      $diskCount++
    }   
    # caso contrario, criar uma nova controladora compartilhada
    else {

      $activeScsiController=New-HardDisk -VM $vm1Name -DiskType $RDM_SHARED_DISK_TYPE -DeviceName /vmfs/devices/disks/naa.$wwn | New-ScsiController -Type ParaVirtual -BusSharingMode Physical
      $diskCount = 1
    }

    if($diskCount -ge $SCSI_CONTROLLER_DISK_LIMIT) {

      $activeScsiController = $false
      $diskCount = 0
    }
  }
}

<#
.SYNOPSIS
Compartilha discos RDM com uma segunda VM

.DESCRIPTION
A partir de um arquivo texto contendo um WWN de LUN por linha, identifica os respectivos discos
na VM de origem, e compartilha os discos com a VM de destino. Os discos sao compartilhados em 
controladoras SCSI espelho.

.PARAMETER wwnFileName
Path do arquivo texto com WWNs

.PARAMETER vm1Name
Nome da VM de origem, que já possui os discos mapeados

.PARAMETER vm2Name
Nome da VM de destino, com a qual os discos serão compartilhados

.EXAMPLE
CreateSharedRdmDiskVm2 -wwnFileName .\wwns.txt -vm1Name vm1157 -vm2Name vm1158
Compartilha os discos disponiveis no arquivo wwns.txt que existem na VM vm1157 com a VM vm1158

.NOTES

#>
function CreateSharedRdmDiskVm2 {
  param(
    $wwnFileName, # arquivo com o wwn dos devices a serem adicionados como RDM
    $vm1Name,     # nome da primeira VM
    $vm2Name      # nome da segunda VM
  )

  # abrir o arquivo texto e iterar entre cada um dos WWNs
  Get-Content $wwnFileName | ForEach-Object {
    $wwn=$_
 
    # adiciona o disco na VM2
    $vm1NewDisk = Get-VM $vm1Name | Get-HardDisk | Where-Object {$_.ScsiCanonicalName -like "naa.${wwn}"}

    $scsiController=Get-ScsiController -HardDisk $vm1NewDisk

    AddSharedHardDisk -vmName $vm2Name -Filename $vm1NewDisk.Filename -Controller $scsiController.Name -isRdm $true
  }
}

<#
.SYNOPSIS
Retorna uma controladora compartilhada com espaço disponivel

.DESCRIPTION
Retorna a primeira controladora SCSI que tiver um ou mais slots de discos disponível. Se nao encontrar nenhuma controladora,
retorna $false

.PARAMETER vmName
nome da VM

.EXAMPLE
GetAvailableSharedScsiController -vmName vm001

.NOTES

#>
function GetAvailableSharedScsiController{

  param(
    $vmName
  )

  $availableScsiController=$false
  $controllers = Get-VM $vmName | Get-ScsiController | Where-Object {$_.BusSharingMode -eq "Physical"} | Sort-Object Name

  # recuperar controladora compartilhada com slot disponível
  foreach ($controller in $controllers) {

    $diskCount = GetScsiControllerDisksCount -vmName $vmName -scsiControllerName $controller.Name

    if ($diskCount -lt $SCSI_CONTROLLER_DISK_LIMIT) {

      $availableScsiController=$controller
      break
    } 
  }

  return $availableScsiController
}

<#
.SYNOPSIS
Retorna a quantidade de discos que existe em uma controladora

.DESCRIPTION
Retorna a quantidade de discos que existe em uma controladora

.PARAMETER vmName
nome da VM

.PARAMETER scsiControllerName
nome da controladora SCSI

.EXAMPLE
GetScsiControllerDisksCount -vmName vm001 -scsiControllerName "SCSI Controller 1"

.NOTES

#>
function GetScsiControllerDisksCount {

  param(
    $vmName,
    $scsiControllerName
  )

  $diskCount = 0
      
  Get-VM $vmName | Get-HardDisk | ForEach-Object {
  
    if($_ | Get-ScsiController | Where-Object {$_.Name -eq $scsiControllerName}) {
      
      $diskCount++;
    }
  }

  return $diskCount
}