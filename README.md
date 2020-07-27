# Description
Getting Cost Management related information from Azure and send it via e-mail.

Find my detailed description on coding.blog -> https://lennart.coding.blog/AzureCostManagementFunction :) 

## Potential Problems and Solutions

### Problem: Body malformated or wrong parameters 
It might be the case that you get an error like: <code>Invoke-WebRequest : {"error":{"code":"400","message":"The remote server returned an error: (400) Bad Request."}</code>
when you are calling <code>"$response = Invoke-WebRequest -Uri $uriCostManagement -Method Post -H ...</code> This usuablly happens if the body is malformated or if the parameters used in the body are not correct.
#### Solution: Body malformated or wrong parameters
Try changing the parameters (e.g EUR to USD or the other way around) and have a look at the prerequisites:<br>
#Name of the budget that exists on the subscription (*Must exist*)<br>
<code> $budgetname = "testbudget" </code><br>
#Name of the Resource Tag that can be used to group costs (CostCenter Tag would be ideal; *Tag must exist*)<br>
<code> $costCenterTag = "costcenter"</code><br>
#Abbreviation of the currency the Enterprise Agreement has been created under (for most German Customers it will be "EUR" instead of "USD")<br>
<code> $currency = "USD" </code>
