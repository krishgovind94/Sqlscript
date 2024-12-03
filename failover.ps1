#
        
        Comment:    Failover all the AGs into secondary node

#>
# ops-sql-flip-ag-to-secondary.ps1
# this script connectes to a sql instance and checks which server is primary AG replica and fails it over to a secondary replica
# this script is meant to be executed from the root of database-scripts folder
# $PerformFailover Invoke failover if the value is $true
# Script will check DB state, if it not online, it will wait for user input to proceed. User input will prompt only if $PerformFailover is $true
# Script will check synchronization_state, if it is 3 = Reverting/4 = Initializing, it will wait for user input to proceed. User input will prompt only if $PerformFailover is $true
# Script will check log_send_queue_size, if it is >500 , it will wait for user input to proceed. User input will prompt only if $PerformFailover is $true
# Script will check redo_queue_size, if it is >500 , it will wait for user input to proceed. User input will prompt only if $PerformFailover is $true
# Script will check any writes are in progress for the past 10 minutes in sys.dm_exec_requests and prompt, refer query in $SqlQuery 
# Script will run CHECKPOINT against each database which is part of AG
# If the $PerformFailover is $true and any of the above validation fails, user need to input YES to proceed with the failover NO to skipp and proceed with next AG
# All the logs are captured in the log file which is in the root of database-scripts folder
# Get-DbaAgDatabase is taking time for mutiple AG servers, replace with SQL query to get AG/DB health status
# Reference https://docs.microsoft.com/en-us/sql/relational-databases/system-dynamic-management-views/sys-dm-hadr-database-replica-states-transact-sql?view=sql-server-ver15

# V11 - 04/01/2021 -   - Changed logic to handle databases with different collations

Clear-host
# change sql connection timeout
Set-DbatoolsConfig -FullName sql.connection.timeout -Value 15
#Get-DbatoolsConfigValue -FullName sql.connection.timeout
$script:root = "."

[Switch]$PerformFailover = $false
# pickup some instances either by direclty assigning them to the variable or from a file
#$SqlInstances = Get-Content (Join-Path $script:root -ChildPath '\assets\patching\prd-lon-sql-p2v-mar-20210312.csv')
#$SqlInstances = Get-Content (Join-Path $script:root -ChildPath '\assets\patching\prod-lon-sql-patching-sep-20201024.csv')
$SqlInstances = "" # ,""
$ProceedWithFailover="YES" #Don't change this, its used as a control variable 
[Switch]$LogToFile = $false

$WriteThreshold=8000
$Opentrancount=1

# logging
$LogFileName = "\assets\logs\log-$('{0:yyyyMMdd}-{0:HHmmss}.log' -f (Get-Date))"
$Logfile = Join-Path $script:root -ChildPath $LogFileName
if ($LogToFile -eq $true)
{
    Add-content $Logfile -value "timestamp|sqlinstance|connection-status|ag|replica-number|replica-role"
}

$SqlQuery = "IF EXISTS (SELECT * FROM DBAInfo.INFORMATION_SCHEMA.TABLES
             WHERE TABLE_NAME = N'WhoIsActiveGather')
                BEGIN
                  EXEC [master].[dbo].[sp_WhoIsActive] 
                    @get_transaction_info = 1,
                    @get_plans = 1, 
                    @destination_table = 'DBAInfo.dbo.WhoIsActiveGather'
                END" 

$itemsToProcess = $SqlInstances | Measure-Object | Select-Object -ExpandProperty Count
$itemNo = 1

$message="###########################################################################################################################"
Write-Host $message
if($LogToFile -eq $true)
{
Add-content $Logfile -value $message                               
}  

foreach ($sqlInstance in $SqlInstances)
{
    $message="############################################# START SERVER: $sqlInstance ##################################################"
    Write-Host $message  -ForegroundColor Red -BackgroundColor green
    if($LogToFile -eq $true)
    {
        Add-content $Logfile -value $message                               
    }  
    
    $message = $null # reset variable
    $message = "$('[{0:MM/dd/yyyy} {0:HH:mm:ss}]' -f (Get-Date)): [INFO] Connecting to $sqlInstance instance ($itemNo/$itemsToProcess)"
    Write-Host $message -ForegroundColor Yellow
    if($LogToFile -eq $true)
    {
        Add-content $Logfile -value $message                               
    }
   
    ##Cheking long runing process
    $ProcessList=@(Invoke-Sqlcmd -ServerInstance $sqlInstance  -Query $SqlQuery )
                        
    $CurrDt=$null
    $CurrDt=get-date -DisplayHint DateTime -Format "yyyy-MM-dd HH:mm"                        
    ##1000000

    # John Giddings - 04/01/2021 - Added join on "COLLATE DATABASE_DEFAULT" to overcome issues with non-default collation joins
    $SqlSeleQuery="IF EXISTS (SELECT * FROM DBAInfo.INFORMATION_SCHEMA.TABLES
                WHERE TABLE_NAME = N'WhoIsActiveGather')
                BEGIN
                    
                    SELECT  '$v' as IdNo,'$UserName' as username,'$sqlInstance' as instancename,[dd hh:mm:ss.mss] as StartTime,session_id,login_name,writes,collection_time
                    FROM DBAInfo.dbo.WhoIsActiveGather w
                    INNER JOIN master.sys.dm_hadr_database_replica_cluster_states ag ON ag.[database_name] COLLATE DATABASE_DEFAULT =w.[database_name] COLLATE DATABASE_DEFAULT
                    WHERE (open_tran_count>=$Opentrancount
                    AND CONVERT(INT, REPLACE([writes], ',', ''))>=$WriteThreshold)
                    AND CONVERT(VARCHAR, collection_time, 120) >=CONVERT(VARCHAR,'$CurrDt', 120)
                    END"

    #$SqlSeleQuery
    $OpenTrans=@(Invoke-Sqlcmd -ServerInstance $sqlInstance  -Query $SqlSeleQuery ) ##Cheking long runing process
    if($OpenTrans.Count -gt 0)
    {
        Write-Host ""
        Write-Host ""
        $message = "$('[{0:MM/dd/yyyy} {0:HH:mm:ss}]' -f (Get-Date)): [INFO] $sqlInstance is busy, you cannot do the failover!"
        Write-Host $message -ForegroundColor Yellow
        $OpenTrans | Format-Table       
       
    }
    
    
    if ($OpenTrans.Count -gt 0 -and $PerformFailover -eq $True)
    {
    #Write-Host "Following are the activities in progress, wait for the completion" -ForegroundColor Yellow
    #$ProcessList | ForEach {[PSCustomObject]$_} | Format-Table -AutoSize
    $ProceedWithFailover="NO"
    
    } 
    else
    {
    $ProceedWithFailover="YES"
    } 
   
    #Add-content $Logfile -value $message
    #
    $connTest = $null # reset variable
    $connTest = Test-DbaConnection -SqlInstance $sqlInstance -SqlCredential $creds -EnableException:$true -ErrorAction:SilentlyContinue
    
    #Proceed only if no open transaction
    if ($OpenTrans.Count -le 0)
    {
        if ($connTest.ConnectSuccess -eq "True")
        {

        $message="###########################################################################################################################"
        Write-Host $message 
        if($LogToFile -eq $true)
        {
        Add-content $Logfile -value $message                               
        }        
        $message = "$('[{0:MM/dd/yyyy} {0:HH:mm:ss}]' -f (Get-Date)): [INFO] Connected to $sqlInstance instance"
        Write-Host $message -ForegroundColor Green

        if($LogToFile -eq $true)
        {
        Add-content $Logfile -value $message                               
        }

        # fail over AG to current secondary
        # assumes two replicas only!
        $AgCount = Get-DbaAvailabilityGroup -SqlInstance $SqlInstance -SqlCredential $creds -WarningAction SilentlyContinue | Select-Object -ExpandProperty Name | Measure-Object
        $AgCount = $AgCount.Count
        if ($AgCount -gt 0)
        {
            $message = "$('[{0:MM/dd/yyyy} {0:HH:mm:ss}]' -f (Get-Date)): [INFO] Processing $AgCount AG(s) on $sqlInstance instance"
            Write-Host $message -ForegroundColor Green
            if($LogToFile -eq $true)
            {
            Add-content $Logfile -value $message                               
            }
        
            $AgName = Get-DbaAvailabilityGroup -SqlInstance $SqlInstance -SqlCredential $creds | Select-Object -ExpandProperty Name
            $AgName.Name
            foreach ($ag in $AgName)
            {
                #$message = "$('[{0:MM/dd/yyyy} {0:HH:mm:ss}]' -f (Get-Date)): [INFO] Processing $ag AG"
                #Write-Host $message -ForegroundColor Cyan
                #
                               
                $AgReplicaCount = $null # reset variable

                $AgReplicaCount = Get-DbaAvailabilityGroup -SqlInstance $sqlInstance -AvailabilityGroup $ag -SqlCredential $creds | Select-Object AvailabilityReplicas
                $AgReplicaCount =  $AgReplicaCount.AvailabilityReplicas.Count

                if ($AgReplicaCount -gt 1)
                {
                    $message = "$('[{0:MM/dd/yyyy} {0:HH:mm:ss}]' -f (Get-Date)): [INFO] There are $AgReplicaCount AG replicas in $ag AG on $sqlInstance instance"
                    Write-Host $message -ForegroundColor Green
                    if($LogToFile -eq $true)
                    {
                    Add-content $Logfile -value $message                               
                    }
                    
                    $PrimaryReplica = $null # reset variable
                    $AgReplicas = $null # reset variable
                    $SecondaryReplica = $null # reset variable
                    
                    $PrimaryReplica = Get-DbaAvailabilityGroup -SqlInstance $sqlInstance -AvailabilityGroup $ag -SqlCredential $creds | Select-Object -ExpandProperty PrimaryReplica
                    [System.Collections.ArrayList]$AgReplicas = Get-DbaAvailabilityGroup -SqlInstance $sqlInstance -AvailabilityGroup $ag -SqlCredential $creds | foreach { $_.AvailabilityReplicas } | Select-Object Name
                    $AgReplicas = $AgReplicas.Name
                    $AgReplicas.Remove($PrimaryReplica)
                    $SecondaryReplica = $AgReplicas

                    $message = "$('[{0:MM/dd/yyyy} {0:HH:mm:ss}]' -f (Get-Date)): [INFO] Before failover: AG Name: $ag Primary: $PrimaryReplica Secondary: $SecondaryReplica"
                    Write-Host $message -ForegroundColor Green
                    if($LogToFile -eq $true)
                    {
                    Add-content $Logfile -value $message                               
                    }
                    $message="###########################################################################################################################"

                    if ($sqlInstance -eq $PrimaryReplica)
                    {
                        $message = "$('[{0:MM/dd/yyyy} {0:HH:mm:ss}]' -f (Get-Date)): [INFO] $sqlInstance is Primary replica in $ag AG  - failover required!"
                        Write-Host $message -ForegroundColor Yellow
                        if($LogToFile -eq $true)
                        {
                        Add-content $Logfile -value $message                               
                        }
                        
                        ####RP_START####
                        #AGStatusList will take time to execute. It depend on number of databases in the AG group. it checks health status of each database .                       
                        #Checking AG Health
                        
                        $AgHealth  ="SELECT  
                        ag.name ag_name ,
                        ar.replica_server_name ,
                        adc.database_name ,
                        hdrs.database_state_desc ,
                        hdrs.synchronization_state,
                        hdrs.synchronization_state_desc ,
                        hdrs.synchronization_health_desc ,
                        agl.dns_name,
                        ISNULL(hdrs.log_send_queue_size,0) as log_send_queue_size,
                        ISNULL(hdrs.redo_queue_size,0) as redo_queue_size 
                        FROM    sys.dm_hadr_database_replica_states hdrs
                        INNER JOIN sys.availability_groups ag ON hdrs.group_id =ag.group_id                        
                        LEFT  JOIN sys.availability_replicas ar ON ag.group_id = ar.group_id
                                                    AND ar.replica_id = hdrs.replica_id
                        LEFT  JOIN sys.availability_databases_cluster adc ON adc.group_id = ag.group_id
                                                                AND adc.group_database_id = hdrs.group_database_id
                        LEFT  JOIN sys.availability_group_listeners agl ON agl.group_id = ag.group_id
                        WHERE ar.replica_server_name='$SqlInstance' AND ag.name='$ag'"

                        $AgHealthList=@(Invoke-Sqlcmd -ServerInstance $sqlInstance  -Query $AgHealth )                       

                        $message="###########################################################################################################################"
                        Write-Host $message
                        if($LogToFile -eq $true)
                        {
                        Add-content $Logfile -value $message                               
                        }

                         
                        #Check database status
                        #$DBstate=$null
                        $DBstate = @($AgHealthList | SELECT database_state_desc |WHERE database_state_desc -NE 'ONLINE')
                        $DBName=$AgHealthList.database_name
                        if ($DBstate.Count -gt 0)
                        {
                         
                         $message="$('[{0:MM/dd/yyyy} {0:HH:mm:ss}]' -f (Get-Date)): [INFO] Database $DBName is not online"
                         Write-Host $message -ForegroundColor Yellow
                         $ProceedWithFailover="NO"

                            if($LogToFile -eq $true)
                            {
                            Add-content $Logfile -value $message                               
                            }                                                    

                            $message=$AgHealthList|SELECT ag_name,replica_server_name,database_name,database_state_desc

                            if($LogToFile -eq $true)
                            {
                            Add-content $Logfile -value $message                               
                            }

                      
                            $message="###########################################################################################################################"
                            Write-Host $message
                            if($LogToFile -eq $true)
                            {
                            Add-content $Logfile -value $message                               
                            }
                        }

                        #synchronization_state -3-Reverting 4-Initializing
                        
                        $DBstate=$null
                        $DBstate=@($AgHealthList|SELECT synchronization_state|WHERE synchronization_state -In (3,4))

                        if ($DBstate.Count -gt 0)
                        {
                         
                         $message="$('[{0:MM/dd/yyyy} {0:HH:mm:ss}]' -f (Get-Date)): [INFO] DB $DBName is in Reverting/Initializing state"
                         Write-Host $message -ForegroundColor Yellow
                         $ProceedWithFailover="NO"

                            if($LogToFile -eq $true)
                            {
                            Add-content $Logfile -value $message                               
                            }                                                    

                            $message=$AgHealthList|SELECT ag_name,replica_server_name,database_name,synchronization_state

                            if($LogToFile -eq $true)
                            {
                            Add-content $Logfile -value $message                               
                            }
                          $message="###########################################################################################################################"
                            if($LogToFile -eq $true)
                            {
                            Add-content $Logfile -value $message                               
                            }
                        }
                         
                        #log_send_queue_size                        
                        
                        $DBstate=$null
                        $DBstate=@($AgHealthList | SELECT log_send_queue_size |WHERE log_send_queue_size -GT 500)
                        
                        if ($DBstate.Count -gt 0)
                        {
                         
                         $message="$('[{0:MM/dd/yyyy} {0:HH:mm:ss}]' -f (Get-Date)): [INFO] DB $DBName log commint is progress"
                         Write-Host $message -ForegroundColor Yellow
                         $ProceedWithFailover="NO"

                            if($LogToFile -eq $true)
                            {
                            Add-content $Logfile -value $message                               
                            }                                                    

                            $AgHealthList|SELECT ag_name,replica_server_name,database_name,log_send_queue_size| Format-Table -AutoSize
                            $message=$AgHealthList|SELECT ag_name,replica_server_name,database_name,log_send_queue_size,redo_queue_size

                            if($LogToFile -eq $true)
                            {
                            Add-content $Logfile -value $message                               
                            }
                          $message="###########################################################################################################################"
                          Write-Host $message
                           if($LogToFile -eq $true)
                            {
                            Add-content $Logfile -value $message                               
                            }
                        }
                                                 
                        #redo_queue_size 

                        $DBstate=$null
                        $DBstate=@($AgHealthList | SELECT redo_queue_size |WHERE redo_queue_size -GT 500)
                       
                        if ($DBstate.Count -gt 0)
                        {
                        
                         $message="$('[{0:MM/dd/yyyy} {0:HH:mm:ss}]' -f (Get-Date)): [INFO] DB $DBName redo commint is progress"
                         Write-Host $message -ForegroundColor Yellow
                         $ProceedWithFailover="NO"

                            if($LogToFile -eq $true)
                            {
                            Add-content $Logfile -value $message                               
                            }                                                    

                            $AgHealthList|SELECT ag_name,replica_server_name,database_name,redo_queue_size | Format-Table -AutoSize
                            $message=$AgHealthList|SELECT ag_name,replica_server_name,database_name,redo_queue_size

                            if($LogToFile -eq $true)
                            {
                            Add-content $Logfile -value $message                               
                            }
                          $message="###########################################################################################################################"
                          Write-Host $message
                          if($LogToFile -eq $true)
                           {
                            Add-content $Logfile -value $message                               
                           }
                        }
                        ## Trigger check point
                        #$AgHealthList | SELECT database_name | Format-Table
                        #$t=1
                        $DBstate=$null
                        $DBstate=@($AgHealthList | SELECT database_name)
                        foreach ($agDBs in $DBstate)
                        {
                         $DbName=$null
                         $DbName=$agDBs.database_name                        
                         Invoke-Sqlcmd -ServerInstance $sqlInstance  -Query "CHECKPOINT" -Database $DbName                         
                        
                        }
                        
                        ### If database status /synchronization_state -3-Reverting 4-Initializing/log_send_queue_size/redo_queue_size , proceed only if input value YES
                        if ($PerformFailover-eq $true -and $ProceedWithFailover -eq "NO")
                        {
                        $ProceedWithFailover = Read-Host -Prompt 'Do you want to proceed with the failover ? Type [YES] or [NO]' 
                        }
                        if ($ProceedWithFailover -ne "YES")
                        {
                             $ProceedWithFailover="NO"
                        }
                       
                        $message="###########################################################################################################################"
                       
                        Write-Host $message
                        if($LogToFile -eq $true)
                        {
                        Add-content $Logfile -value $message                               
                        }  

                        if ($LogToFile -eq $true)
                        {
                            $message = "$('[{0:MM/dd/yyyy} {0:HH:mm:ss}]' -f (Get-Date)): [INFO] $sqlInstance connected $ag $AgReplicaCount primary"
                            Add-content $Logfile -value $message
                        }
                    }
                    else
                    {
                        $message = "$('[{0:MM/dd/yyyy} {0:HH:mm:ss}]' -f (Get-Date)): [INFO] $sqlInstance is a secondary replica on $ag AG  - no need for failover"
                        Write-Host $message -ForegroundColor Green
                        if ($LogToFile -eq $true)
                        {
                            
                            Add-content $Logfile -value $message
                        }
                        
                        if ($LogToFile -eq $true)
                        {
                            $message = "$('[{0:MM/dd/yyyy} {0:HH:mm:ss}]' -f (Get-Date)): [INFO] $sqlInstance connected $ag|$AgReplicaCount secondary"
                            Add-content $Logfile -value $message
                        }
                    }
                    
                    if ($PerformFailover -eq $True -and $ProceedWithFailover -eq "YES") ##RP added -and $ProceedWithFailover -eq "YES")
                    {

                        if ($sqlInstance -eq $PrimaryReplica)
                        {
                            Write-Host "Primary - failing over"
                             if ($LogToFile -eq $true)
                             {
                                $message = "$('[{0:MM/dd/yyyy} {0:HH:mm:ss}]' -f (Get-Date)): [INFO] Primary - failing over"
                                Add-content $Logfile -value $message
                             }

                            # To Failover
                            Invoke-DbaAgFailover -SqlInstance $SecondaryReplica -AvailabilityGroup $ag -SqlCredential $creds -Confirm:$false  | Out-Null

                            $PrimaryReplica = Get-DbaAvailabilityGroup -SqlInstance $sqlInstance -AvailabilityGroup $ag -SqlCredential $creds | Select-Object -ExpandProperty PrimaryReplica
                            [System.Collections.ArrayList]$AgReplicas = Get-DbaAvailabilityGroup -SqlInstance $sqlInstance -AvailabilityGroup $ag -SqlCredential $creds | foreach { $_.AvailabilityReplicas } | Select-Object Name
                            $AgReplicas = $AgReplicas.Name
                            $AgReplicas.Remove($PrimaryReplica)
                            $SecondaryReplica = $AgReplicas

                            $message = "$('[{0:MM/dd/yyyy} {0:HH:mm:ss}]' -f (Get-Date)): [INFO] AG after failover: AG Name: $ag Primary: $PrimaryReplica Secondary: $SecondaryReplica"
                            Write-Host $message -ForegroundColor Green                                
                            #Set-DbaAgReplica -SqlInstance $PrimaryReplica -Replica $PrimaryReplica, $SecondaryReplica -AvailabilityGroup $ag  -FailoverMode Automatic -SqlCredential $creds -Confirm:$false | Out-Null
                            if ($LogToFile -eq $true)
                            {                            
                            Add-content $Logfile -value $message
                            }
                          
                            
                        }
                        else
                        {
                            $message = "$('[{0:MM/dd/yyyy} {0:HH:mm:ss}]' -f (Get-Date)): [INFO] Secondary - no need for failover"
                            Write-Host $message -ForegroundColor Green 
                            if ($LogToFile -eq $true)
                            {                            
                            Add-content $Logfile -value $message
                            }   
                        }
                    }                  

                    
                }
                
                else
                {
                    $message = "$('[{0:MM/dd/yyyy} {0:HH:mm:ss}]' -f (Get-Date)): [INFO] Single replica in $ag AG on $sqlInstance instance. Nothing to fail over!"
                    Write-Host $message -ForegroundColor Yellow
                    
                    if ($LogToFile -eq $true)
                    {
                        $message = "$('[{0:MM/dd/yyyy} {0:HH:mm:ss}]' -f (Get-Date)): [INFO] $sqlInstance connected $ag $AgReplicaCount primary"
                        Add-content $Logfile -value $message
                    }
                }    
            }
        }
        else
        {
            $message = "$('[{0:MM/dd/yyyy} {0:HH:mm:ss}]' -f (Get-Date)): [INFO] There are no AGs on $sqlInstance instance. Skipping!"
            Write-Host $message -ForegroundColor Green

            if ($LogToFile -eq $true)
            {
                $message = "$('[{0:MM/dd/yyyy} {0:HH:mm:ss}]' -f (Get-Date)): [INFO]  $sqlInstance connected no-ag|n/a|n/a"
                Add-content $Logfile -value $message
            }
        }
        
    }
        else
        {
            $message = "$('[{0:MM/dd/yyyy} {0:HH:mm:ss}]' -f (Get-Date)): [ERROR] Cannot connect to $sqlInstance instance"
            Write-Host $message -ForegroundColor Red
            if($LogToFile -eq $true)
            {
                $message = "$('[{0:MM/dd/yyyy} {0:HH:mm:ss}]' -f (Get-Date))|$sqlInstance|unavailable|n/a|n/a|n/a"
                Add-content $Logfile -value $message
            }
        }
            
     }   
        $message="############################################## END SERVER: $sqlInstance ###################################################"
        Write-Host $message -ForegroundColor Red -BackgroundColor green
        if($LogToFile -eq $true)
        {
        Add-content $Logfile -value $message                               
        }            
    $itemNo = $itemNo + 1
       
}
