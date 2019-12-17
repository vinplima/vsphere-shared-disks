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

Functions em Powershell para apoiar na gestão de discos compartilhados no ambiente vSphere.

## Functions

* createSharedFlatHardDisk - Cria disco compartilhado entre duas máquinas virtuais. O disco criado é do tipo Flat.
* shutdownVmGuestSync - Desliga a VM pelo guest de modo síncrono. Essa opção não está implementada por padrão.
* allowVmDiskMultiWriter - Ativa o MultiWriter no disco virtual.
* addSharedHardDisk - Adiciona HD de uma VM em outra VM.
* createSharedRdmDisk - Cria discos RDM compartilhados.

## Compatibility

vSphere 6.x.

## Example

~~~
# import do script
. .\sharedDisksFunctions.ps1

# cria um disco compartilhado flat entre duas VMs
createSharedFlatHardDisk -vm1Name 'vmfoo01' -vm2Name 'vmbar01' -capacityGB 50
~~~

## Release Notes

v0.1 - Adicionados os scripts ao GIT
