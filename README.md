# vSphere Shared Disks

#### Table of Contents

- [vSphere Shared Disks](#vsphere-shared-disks)
      - [Table of Contents](#table-of-contents)
  - [Description](#description)
  - [Functions](#functions)
  - [Compatibility](#compatibility)
  - [Example](#example)
  - [Release Notes](#release-notes)

## Description

Funções em Powershell para apoiar na gestão de discos compartilhados no ambiente vSphere.

## Functions

* CreateSharedFlatHardDisk - Cria disco compartilhado entre duas máquinas virtuais. O disco criado é do tipo Flat.
* ShutdownVmGuestSync - Desliga a VM pelo guest de modo síncrono. Essa opção não está implementada por padrão.
* AllowVmDiskMultiWriter - Ativa o MultiWriter no disco virtual.
* AddSharedHardDisk - Adiciona HD de uma VM em outra VM.
* CreateSharedRdmDisk - Cria discos RDM compartilhados.
* GetVmAvailableSharedDisksSlots - Recupera o montante de discos compartilhados que podem ser criados/adicionados na VM
* CreateSharedRdmDiskVm1 - Cria disco RDM compartilhavel em uma VM
* CreateSharedRdmDiskVm2 - Compartilha disco RDM de uma VM com outra VM
* GetAvailableSharedScsiController - Recupera um objeto SCSIController que representa uma SCSI Controller compartilhada com slots disponiveis
* GetScsiControllerDisksCount - Recuera a quantidade de discos existentes em uma determinada SCSI Controller

## Compatibility

vSphere 6.x.

## Example
Importa funções no ambiente e cria disco Flat de 50GB compartilhado entre duas VMs

~~~
. .\sharedDisksFunctions.ps1

CreateSharedFlatHardDisk -vm1Name 'vmfoo01' -vm2Name 'vmbar01' -capacityGB 50
~~~

Recupera exemplos de execução da função GetAvailableSharedScsiController

~~~
> Get-Help GetAvailableSharedScsiController -example

NOME
    GetAvailableSharedScsiController

SINOPSE
    Retorna uma controladora compartilhada com espaco disponivel


    -------------------------- EXEMPLO 1 --------------------------

    PS C:\>GetAvailableSharedScsiController -vmName vm001

~~~

## Release Notes

v0.1 - Adicionados os scripts ao GIT
