name 'Pingdom Security Group Rules'
rs_ca_ver 20160622
short_description "Pingdom Security Group Rules"

#Copyright 2017 RightScale
#
#Licensed under the Apache License, Version 2.0 (the "License");
#you may not use this file except in compliance with the License.
#You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
#Unless required by applicable law or agreed to in writing, software
#distributed under the License is distributed on an "AS IS" BASIS,
#WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#See the License for the specific language governing permissions and
#limitations under the License.

#RightScale Cloud Application Template (CAT)

# DESCRIPTION
# Finds long running instances and reports on them
#


##################
# User inputs    #
##################
parameter "parameter_check_frequency" do
  category "User Inputs"
  label "Minutes between each check."
  type "number"
  default 1
  min_value 1
end

parameter "parameter_pingdom_last_build_date" do
  category "Advanced"
  label "Pingdom lastBuildDate"
  description "Ignore this parameterif you are unsure with how it is used."
  type "string"
  default " "
end



##################
# Definitions    #
##################

####################
# OPERATIONS       #
####################
operation "launch" do
  description "Sync Pingdom Probes with Security Group Rules"
  definition "launch_syncPingdomSecurityGroupRules"
end

operation "syncPingdomSecurityGroupRules" do
  description "Sync Pingdom Probes with Security Group Rules"
  definition "syncPingdomSecurityGroupRules"
end

define launch_syncPingdomSecurityGroupRules($parameter_check_frequency)  do
    call syncPingdomSecurityGroupRules($parameter_check_frequency,'')
end


define getPingdomProbes() return $pingdomProbes,$pingdomProbesLastBuildDate do  
  $response = http_get( url: "https://my.pingdom.com/probes/feed" )
  $pingdomFeed = $response["body"]["rss"]["channel"]["item"]
 

  $pingdomProbes={ "NA":[], "EU":[], "APAC":[], "Misc":[] }
  $pingdomProbesLastBuildDate = $response["body"]["rss"]["channel"]["lastBuildDate"]

  foreach $probe in $pingdomFeed do
      if $probe["region"] =~ "(NA|EU|APAC)"
        $pingdomProbes[$probe["region"]]  =    $pingdomProbes[$probe["region"]] + [$probe]
      else
        $pingdomProbes["Misc"]            =    $pingdomProbes["Misc"] + [$probe]
      end
  end
 
end

define retry_syncPingdomSecurityGroupRules($attempts) do
  if $attempts <= 3
    $_error_behavior = "retry"
  end
end

define syncPingdomSecurityGroupRules($parameter_check_frequency,$parameter_pingdom_last_build_date) do
  $attempts = 0
  sub on_error: retry_syncPingdomSecurityGroupRules($attempts) do
    $attempts = $attempts + 1
    #Setup Security Group Href Hash 
    $pingdomSecurityGroupHref_NA = "/api/clouds/3/security_groups/6EL0AN0EC8J7"
    $pingdomSecurityGroupHref_EU = "/api/clouds/3/security_groups/DVVVNKO74NVMJ"
    $pingdomSecurityGroupHref_APAC = "/api/clouds/3/security_groups/DBDSFK3LE01FK"
    $pingdomSecurityGroupHref_Misc = "/api/clouds/3/security_groups/F9TGQ869SOK3B" 

    $pingdomSecurityGroups = {
      "NA":  {  "sg_href": $pingdomSecurityGroupHref_NA  },
      "EU":  {  "sg_href": $pingdomSecurityGroupHref_EU  },
      "APAC": {  "sg_href": $pingdomSecurityGroupHref_APAC    },
      "Misc": {  "sg_href": $pingdomSecurityGroupHref_Misc    }
    }
  

    #Setup Pingdom Probes Array
    call getPingdomProbes() retrieve $pingdomProbes, $pingdomProbesLastBuildDate

    task_label('Comparing Pingdom Probe Feeds [[ Current: '+$pingdomProbesLastBuildDate+' | Last: '+$parameter_pingdom_last_build_date+' ]]')

    if $pingdomProbesLastBuildDate != $parameter_pingdom_last_build_date
      task_label('Pingdom Probes Feed has been updated, checking security group rules')

      foreach $region in ['NA','EU','APAC','Misc'] do
        task_label('Processing ' + $region + ' Security Group ['+$pingdomSecurityGroups[ $region ]["sg_href"]+']')

        $active_probes=[]
        foreach $probe in $pingdomProbes[$region] do
          $active_probes << $probe["ip"]+'/32'
        end
    
    
      #removeOldPingdomSecurityGroupRules
      $existing_probes=[]
      @sg_rules = rs_cm.get(href: $pingdomSecurityGroups[$region]["sg_href"]+"/security_group_rules")
      foreach @sg_rule in @sg_rules do
        $sg_rule = to_object(@sg_rule)
        if to_s($sg_rule["details"][0]["description"]) =~ "Pingdom Probe - Created by CloudApp" 
          task_label('Checking if ' + to_s($sg_rule["details"][0]["cidr_ips"])+'/32 is still currently active')
          if any?($active_probes, to_s($sg_rule["details"][0]["cidr_ips"]))
              task_label('Leaving ' + $sg_rule["details"][0]["cidr_ips"] + ' because it is still currently active')
              $existing_probes << $sg_rule["details"][0]["cidr_ips"]
          else
              task_label('Removing ' + $sg_rule["details"][0]["cidr_ips"] + ' because it is NOT currently active')
              @sg_rule.destroy()
          end
    
        end
      end
    
      #addPingdomSecurityGroupRules
      foreach $probe in $pingdomProbes[$region] do
        if any?($existing_probes,$probe["ip"]+'/32')
          task_label('Rule already exists for ' + $probe["ip"] + ' - skipping')
        else
          task_label('Creating rule for ' + $probe["ip"] + ' in ' + $region + ' security group')
          $rule = {
              "security_group_href":$pingdomSecurityGroups[$region]["sg_href"],
              "cidr_ips":$probe["ip"]+"/32",
              "protocol":"tcp",
              "source_type":"cidr_ips",
              "direction":"ingress",
              "protocol_details": {
                "start_port":"80",
                "end_port":"80"
                },
              "description": "Pingdom Probe - Created by CloudApp"
              }
          @new_rule = rs_cm.security_group_rules.create(security_group_rule: $rule)
          @new_rule.update(security_group_rule: { "description": "Pingdom Probe - Created by CloudApp" })
        end
    end
    
    
        #validatePingdomSecurityGroupRules
      end

      
    end
    task_label('Scheduling next check')
    call schedule_next_check($parameter_check_frequency,$pingdomProbesLastBuildDate)
  end
end

























##############
## INCLUDES ##
##############


define schedule_next_check($check_frequency,$pingdom_last_build) do
#Creates a scheduled action to do another check in user-specified minutes

#  call logger(@@deployment, "Scheduling next action in "+$check_frequency+" minutes", "")

  $action_name = "check_" + last(split(@@deployment.href,"/"))

  call find_shard(@@deployment) retrieve $shard
  call sys_get_execution_id() retrieve $execution_id
  call sys_get_account_id() retrieve $account_id

  # delete the old action that ran to get us here.
  call delete_scheduled_action($shard, $execution_id, $account_id, $action_name)

  call login_to_self_service($account_id, $shard)

  $parms = {execution_id: $execution_id, action: "run", first_occurrence: now() + ($check_frequency*60), name: $action_name,
    operation: {"name":"syncPingdomSecurityGroupRules",
      "configuration_options":[
        {
          "name":"parameter_check_frequency",
          "type":"number",
          "value":$check_frequency
        },
        {
          "name":"parameter_pingdom_last_build_date",
          "type":"string",
          "value":$pingdom_last_build
        }]
     }
    }  

  $response = http_post(
    url: "https://selfservice-"+$shard+".rightscale.com/api/manager/projects/" + $account_id + "/scheduled_actions",
    headers: { "X-Api-Version": "1.0", "accept": "application/json" },
    body: $parms
  )

#  call logger(@@deployment, "Next schedule post response", to_s($response))

end

# Delete's scheduled action.
define delete_scheduled_action($shard, $execution_id, $account_id, $action_name)  do

  call login_to_self_service($account_id, $shard)

  $response = http_get(
    url: "https://selfservice-" + $shard + ".rightscale.com/api/manager/projects/" + $account_id + "/scheduled_actions?filter[]=execution_id==" + $execution_id + "&filter[]=execution.created_by==me",
    headers: { "X-Api-Version": "1.0", "accept": "application/json" }
  )

  $jbody = from_json($response["body"])

  foreach $action in $jbody do
    if $action["name"] == $action_name
      $response = http_delete(
        url: "https://selfservice-" + $shard + ".rightscale.com" + $action["href"],
        headers: { "X-Api-Version": "1.0", "accept": "application/json" }
      )
    end
  end
end


define sys_get_execution_id() return $execution_id do
# Fetches the execution id of "this" cloud app using the default tags set on a
# deployment created by SS.
# selfservice:href=/api/manager/projects/12345/executions/54354bd284adb8871600200e
#
# @return [String] The execution ID of the current cloud app
  call get_tags_for_resource(@@deployment) retrieve $tags_on_deployment
  $href_tag = map $current_tag in $tags_on_deployment return $tag do
    if $current_tag =~ "(selfservice:href)"
      $tag = $current_tag
    end
  end

  if type($href_tag) == "array" && size($href_tag) > 0
    $tag_split_by_value_delimiter = split(first($href_tag), "=")
    $tag_value = last($tag_split_by_value_delimiter)
    $value_split_by_slashes = split($tag_value, "/")
    $execution_id = last($value_split_by_slashes)
  else
    $execution_id = "N/A"
  end

end

define sys_get_account_id() return $account_id do
# Fetches the account id of "this" cloud app using the default tags set on a
# deployment created by SS.
# selfservice:href=/api/manager/projects/12345/executions/54354bd284adb8871600200e
#
# @return [String] The account ID of the current cloud app
  call get_tags_for_resource(@@deployment) retrieve $tags_on_deployment
  $href_tag = map $current_tag in $tags_on_deployment return $tag do
    if $current_tag =~ "(selfservice:href)"
      $tag = $current_tag
    end
  end

  if type($href_tag) == "array" && size($href_tag) > 0
    $tag_split_by_value_delimiter = split(first($href_tag), "=")
    $tag_value = last($tag_split_by_value_delimiter)
    $value_split_by_slashes = split($tag_value, "/")
    $account_id = $value_split_by_slashes[4]
  else
    $account_id = "N/A"
  end

end

define login_to_self_service($account_id, $shard) do
  $response = http_get(
    url: "https://selfservice-"+$shard+".rightscale.com/api/catalog/new_session?account_id=" + $account_id
  )

#  call logger(@@deployment, "login to self service response", to_s($response))

end

# Returns the RightScale shard for the account the given CAT is launched in.
# It relies on the fact that when a CAT is launched, the resultant deployment description includes a link
# back to Self-Service.
# This link is exploited to identify the shard.
# Of course, this is somewhat dangerous because if the deployment description is changed to remove that link,
# this code will not work.
# Similarly, since the deployment description is also based on the CAT description, if the CAT author or publisher
# puts something like "selfservice-8" in it for some reason, this code will likely get confused.
# However, for the time being it's fine.
define find_shard(@deployment) return $shard_number do

  $deployment_description = @deployment.description
  #rs_cm.audit_entries.create(notify: "None", audit_entry: { auditee_href: @deployment, summary: "deployment description" , detail: $deployment_description})

  # initialize a value
  $shard_number = "UNKNOWN"
  foreach $word in split($deployment_description, "/") do
    if $word =~ "selfservice-"
    #rs_cm.audit_entries.create(notify: "None", audit_entry: { auditee_href: @deployment, summary: join(["found word:",$word]) , detail: ""})
      foreach $character in split($word, "") do
        if $character =~ /[0-9]/
          $shard_number = $character
          #rs_cm.audit_entries.create(notify: "None", audit_entry: { auditee_href: @deployment, summary: join(["found shard:",$character]) , detail: ""})
        end
      end
    end
  end
end


define get_tags_for_resource(@resource) return $tags do
# Returns all tags for a specified resource. Assumes that only one resource
# is passed in, and will return tags for only the first resource in the collection.
#
# @param @resource [ResourceCollection] a ResourceCollection containing only a
#   single resource for which to return tags
#
# @return $tags [Array<String>] an array of tags assigned to @resource
  $tags = []
  $tags_response = rs_cm.tags.by_resource(resource_hrefs: [@resource.href])
  $inner_tags_ary = first(first($tags_response))["tags"]
  $tags = map $current_tag in $inner_tags_ary return $tag do
    $tag = $current_tag["name"]
  end
  $tags = $tags
end

define logger(@deployment, $summary, $details) do
  rs_cm.audit_entries.create(
    notify: "None",
    audit_entry: {
      auditee_href: @deployment,
      summary: $summary,
      detail: $details
      }
    )
end

