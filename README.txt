BigCommerceAudit
Created by: David Barnes
Requirements: ImportExcel, SqlServer

*******************************************************************************
* To use this tool you need to install the ImportExcel and SqlServer modules. * 
* All you need to do is run the below commands in Powershell.                 *
* It does not require Administrator credentials.                              *
*                                                                             *
* Install-Module -Name ImportExcel -Scope CurrentUser -Force                  *     
* Install-Module -Name SqlServer -Scope CurrentUser -Force                    *
*******************************************************************************

This tool is used for auditing BigCommerce and queries BigCommerce's GraphQL endpoint to pull the information related to the audit. There are currently two audits available in the tool: Price Mismatches (between Celerant and BigCommerce) and Product Weights.

For Price Mismatches, SKU (product-level, not variant-level) and Price values are pulled in and compared against Celerant to identify price mismatches. It specifically ONLY looks at products in BigCommerce that are "in stock" in order to weed out inactive items with sale prices. This option requires SQL database credentials. If you do not have them, ask AJ.

For Product Weights, SKU and Weight values are pulled in and sent to a CSV file if under 1 pound. This metric is significant because 1 pound is the threshold to allow USPS First Class mail and we want to be careful about which products we allow that shipping method for considering it needs to fit in an envelope. Products reported in this audit should be checked and have their weight increased to 1 if they should not be available for USPS First Class mail.

***********************************************************************************************************************************
* NOTE                                                                                                                            *
* The GraphQL API used by this tool requires a "Token" in config.json.                                                            *
* This token naturally expires and changes fairly frequently so there is a chance you will need to obtain a new "Token" yourself. *
*                                                                                                                                 *
* To obtain a new token:                                                                                                          *
* Go to BigCommerce -> Settings -> API -> Storefront API Playground                                                               *
* Look near the bottom where you see a "Headers" label that contains an "Authorization": "Bearer..." code                         *
* Copy that token starting with the first character AFTER the "Bearer" text and replace the token in config.json                  *
***********************************************************************************************************************************

HOW TO USE PRICE MISMATCHES:

1. Allow script to run to completion then open the resulting PriceMismatches.csv file. This file is sorted by SKU but I recommend adding a filter and sorting the price difference column to allow you to cherry pick what data you wish to see.

NOTE: This tool is not perfect at all and mismatches can falsely appear several ways:

1. When Product Codes get reused in Celerant. For example if there are two "40000" products in Celerant and BigCommerce has a product page for one of those, there's a chance this tool will reference the wrong price that will depend *which* product was set up in BigCommerce relative to the order the product was entered in Celerant.

2. When there is variant/sku-level pricing. If a particular product has a base price of 54.95 in Celerant but some skus are 59.95, the Celerant price being referenced will likely be the max for that product while BigCommerce operates the opposite way where it'll look at the base price which is most often the smallest/cheapest variant when multiples exist. This is most noticeable in pet food and pet apparel.

3. I believe that, with the way products USED to be imported or configured in BigCommerce, there can be prices that are hidden. I haven't seen this happen too often but I have definitely encountered more than one product that GraphQL said the price was one value but when I viewed the product page, that particular price was nowhere to be found even among variants.

If the difference in price between Celerant and BigCommerce is large (greater than $10 for footwear, greater than $2 for pet supplies) it probably indicates there are variants with different pricing. If the price difference is smaller than that, it's probably a sign that a price change happened in Celerant that didn't happen in BigCommerce. Do not ignore the former though because a price change still could have been missed. Additionally, it's not a bad idea to copy the skus of products with variable variant pricing and search them in Celerant to verify the pricing on those is accurate.

This tool would provide much more reliable data if the BigCommerce GraphQL API reliably pulled in all skus but it seems like internally there may have been some things that have changed over the years resulting in variants not appearing in the variants data objects despite appearing as variants in the web interface. Unless and until I can find a solution to that, the data provided will be sketchy. 

All that being said, the information that matters most is the products where **BigCommerce's price is LOWER than Celerant's price**. Sometimes, prices on BigCommerce are slightly higher than in-store and that is intentional, however the inverse should not be true without promos being involved. Therefore, use this tool merely as a guide to understand which products warrant investigation.

HOW TO USE PRODUCT WEIGHT:

1. Allow the script to run then open the ProductWeights.csv file that generates.

2. Both the "Entity" and "SKU" values are searchable within BigCommerce so for each record find the associated product. Give the product a quick glance and make a judgement call on if that is something we could reasonably ship in an envelope. If it cannot, update the weight to 1 pound. If it can, leave it as-is.

3. This data will update in BigCommerce as you update the weights so if you run this option following updating a batch of items, your CSV file should be smaller now that those products do not appear in the CSV file.


HOW TO USE INACTIVITY CHECKER:

1. Allow the script to run then open the InactiveProducts.csv file that generates.

2. Anything in this spreadsheet is one of two categories of products in BigCommerce:

	a. A product that correlates to an Inactive product in Celerant
	
	b. A product that correlates to a product in Celerant that COULD be made Inactive but is still Active.
	
3. A flag is included in the spreadsheet called "Inactive" that indicates if a product is inactive in Celerant. If you only want to deal with those products, you can just use a filter or sort and pick those products.

4. It should be noted I am not entirely confident in the completeness of any query we get from GraphQL given my attempt at a robust dataset from the Price Mismatches function. The collection of data may actually be fine since I am not trying to pull variant-level info which is where I had problems under Price Mismatches. Just keep in mind you're always able to just look at what the tool outputs as total SKUs processed and compare that against what BigCommerce says our product total is. Whatever that difference is is how many products didn't get picked up by the GraphQL query.

HOW TO RUN:
Right-click BigCommerceAudit.ps1 and select "Run with PowerShell"

Alternatively, Shift + Right-click anywhere in the folder (don't Shift + Right-click the file itself) and select "Open PowerShell window here" to open a PowerShell window first. This will make it so the command prompt window won't close as soon as this tool finishes which will let you inspect the output if you wish. To run the script with this method, type (or copy and paste) the following:

./BigCommerceAudit.ps1

HOW TO INSTALL MODULES:
Open PowerShell by searching for it with the Start menu or shift + right-click the whitespace of any folder's window and click "Open PowerShell window here"
Copy and paste the Install-Module commands into PowerShell. If the modules are already installed, they will be ignored.

HOW TO UPDATE GRAPHQL CREDENTIALS:
When a tool needs to query BigCommerce's data, it needs to do it via a GraphQL query which requires an Authorization token that comes from BigCommerce. It expires around once per week meaning there is a decent chance you will need to obtain that token if you are running this tool. To get that token, go to the following location in BigCommerce: 

Settings -> Storefront API Playground

In the page that opens, look near the bottom under a "Headers" tab. Find the "Authorization" text and look for a block of text immediately after it that starts with "Bearer ..."

The string of text starts AFTER the "Bearer" text is the GraphQL token. Copy that and paste it in the config.json value under the BigCommerce -> Token field. The existing value should already look pretty close to the token you have so use that to verify you have the right information.