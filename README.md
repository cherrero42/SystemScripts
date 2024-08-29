# System Scripts


## @file backup.sh
 
 @brief Script for local backup, offsite synchronization, and backup retention management.

 This script performs the following tasks:
 - Synchronizes the local backup with an offsite location.
 - Manages backup retention according to predefined policies.

 The script ensures that backups are regularly created and synchronized, 
 and old backups are deleted based on the retention rules to save space 
 and maintain backup efficiency.


 ## @file update_host.yml
 
 @brief Ansible playbook to update packages and log the process.
 
 @details 
 This playbook performs a series of tasks on the specified hosts to update the 
 system packages and log the process to a designated folder. It is designed 
 for systems with apt package management.
