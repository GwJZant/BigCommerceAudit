# Load the configuration file
$configFile = "$PSScriptRoot\config.json"

if (Test-Path $configFile) {
    # Read the file and convert JSON into a PowerShell Object
    $config = Get-Content -Path $configFile -Raw | ConvertFrom-Json
} else {
    Write-Host "ERROR: config.json not found!" -ForegroundColor Red
    exit
}

# Output filename formatting
# Check if the folder exists; if not, create it
if (-not (Test-Path -Path "$PSScriptRoot\Output")) {
    # -Force ensures it creates the entire tree if multiple levels are missing
    New-Item -ItemType Directory -Path "$PSScriptRoot\Output" -Force | Out-Null
}

$timestamp = Get-Date -Format "yyyy-MM-dd_HHmm"
$outputFolderPath = "$PSScriptRoot\Output\"

# Setup API Credentials
$token = $config.BigCommerce.Token
$url   = $config.BigCommerce.GraphQLEndpoint

$hasNextPage    = $true
$endCursor      = $null
$productCount   = 0

# Menu
Write-Host "What do you want to audit?" -ForegroundColor Cyan
Write-Host "1. Price Mismatches" -ForegroundColor Cyan
Write-Host "2. Product Weights" -ForegroundColor Cyan
Write-Host "3. Inactivity Checker" -ForegroundColor Cyan
Write-Host "4. Missing Products (Required: Input\BigCommerceProducts.txt)" -ForegroundColor Cyan
Write-Host "5. Exit" -ForegroundColor Cyan
$selection = Read-Host "Enter your selection"

if ($selection -eq "1") {
	$allBcPrices    = @{} # A 'Hash Table' to store SKU => Price for fast lookup
	
	Write-Host "Fetching all in stock products from BigCommerce (this may take a minute)..." -ForegroundColor Cyan

	while ($hasNextPage) {
		# If we have a cursor, we tell GraphQL where to start the next page
		$after = if ($endCursor) { "after: `"$endCursor`"" } else { "" }
		
		# 2. Define the GraphQL Query
		# This asks for 50 products, their SKU, and their current price
		$graphQuery = @{
			query = "query {
				site {
					products (first: 50 $after) {
						pageInfo { hasNextPage endCursor }
						edges {
							node {
								entityId
								inventory {
									isInStock
								}
								sku
								prices {
									price {
										value
									}
								}
							}
						}
					}
				}
			}"
		} | ConvertTo-Json
		
		$headers = @{
			"Authorization" = "Bearer $token"
			"Content-Type"  = "application/json"
		}

		$response = Invoke-RestMethod -Uri $url -Method Post -Headers $headers -Body $graphQuery
		
		# Write-Host "Debug: hasNextPage = $($response.data.site.products.pageInfo.hasNextPage) | Cursor = $($response.data.site.products.pageInfo.endCursor)"

		# Drill down into the data
		$bcProducts = $response.data.site.products.edges

		foreach ($productEdge in $bcProducts) {
			$p = $productEdge.node
			$productCount++
			
			if ($p.sku) {
				if ($p.inventory.isInStock) {
					$allBcPrices[$p.sku] = [decimal]$($p.prices.price.value)
				} else {
					# Write-Host "SKU: $($p.sku) NOT in stock."
				}			
			} else {
				# Write-Host "No SKU from entity: $($p.entityId) Price: $($p.prices.price.value)"
			}			
		}
		
		# Check if there's another page
		$hasNextPage = $response.data.site.products.pageInfo.hasNextPage
		$endCursor   = $response.data.site.products.pageInfo.endCursor

		if ($productCount % 500 -eq 0) {
			Write-Host "Collected $($allBcPrices.Count) SKUs from $($productCount) Products so far..."
		}
	}

	Write-Host "Total: Collected $($allBcPrices.Count) SKUs from $($productCount) Products."

	# Connect to Celerant Database
	Write-Host "Connecting to Celerant Database and comparing prices..." -ForegroundColor Cyan

	# Set up SQL parameters
	$sqlParams = @{
		ServerInstance         = $config.Celerant.ServerInstance
		Database               = $config.Celerant.Database
		Query                  = "SELECT DISTINCT styles.STYLE AS SKU, tickets.PRICE AS PRICE, tickets.DESCRIPTION AS DESCRIPTION, tickets.DEPT AS DEPT FROM TB_STYLES styles
									INNER JOIN VW_TICKETS tickets
									ON tickets.STYLE_ID = styles.STYLE_ID
									AND tickets.STORE_ID = 1
									WHERE styles.OF5 = ''
									AND styles.STATUS_FINISH = 'N';"
		Username               = $config.Celerant.Username
		Password               = $config.Celerant.Password
		Encrypt                = "Mandatory"
		TrustServerCertificate = $true
	}

	try {
		$posData = Invoke-Sqlcmd @sqlParams
		
		$mismatches = @()
		$notFoundInBC = 0
		$foundInBC = 0

		foreach ($row in $posData) {
			$sku         = $row.SKU
			$posPrice    = [decimal]$row.Price
			$bcPrice     = [decimal]$allBcPrices[$sku]
			$productName = $row.Description
			$dept        = $row.Dept
			
			if ($allBcPrices.ContainsKey($sku)) {
				
				$foundInBC++
				
				if (($allBcPrices[$sku] -ne $posPrice) -and ($dept -notlike "*FOOD*")) {
					$mismatches += [PSCustomObject]@{
						SKU      = $sku
						Name     = $productName
						DEPT     = $dept
						PosPrice = $posPrice
						BcPrice  = $bcPrice
						Diff     = $posPrice - $bcPrice
					}
				}
			} else {
				$notFoundInBC++
			}
		}

		# Final Report
		Write-Host "`nAudit Complete!" -ForegroundColor Green
		Write-Host "Mismatches Found: $($mismatches.Count)"
		
		$outputFile = $outputFolderPath + "PriceMismatches" + $timestamp + ".csv"
		
		if ($mismatches.Count -gt 0) {
			$mismatches | Sort-Object SKU | Export-Csv -Path $outputFile -NoTypeInformation
			Write-Host "Results exported to $outputFile" -ForegroundColor Yellow
		}
	} catch {
		Write-Host "SQL Error: $_" -ForegroundColor DarkRed
	}
} elseif ($selection -eq "2") {
	$allBcWeights   = @() # list of objects used for Product Weights option

	Write-Host "Fetching all products from BigCommerce (this may take a minute)..." -ForegroundColor Cyan

	while ($hasNextPage) {
		# If we have a cursor, we tell GraphQL where to start the next page
		$after = if ($endCursor) { "after: `"$endCursor`"" } else { "" }
		
		# 2. Define the GraphQL Query
		# This asks for 50 products, their SKU, and their current price
		$graphQuery = @{
			query = "query {
				site {
					products (first: 50 $after) {
						pageInfo { hasNextPage endCursor }
						edges {
							node {
								entityId
								sku
								name
								availability
								weight {
									unit
									value
								}
								inventory {
									isInStock
								}
							}
						}
					}
				}
			}"
		} | ConvertTo-Json
		
		$headers = @{
			"Authorization" = "Bearer $token"
			"Content-Type"  = "application/json"
		}

		$response = Invoke-RestMethod -Uri $url -Method Post -Headers $headers -Body $graphQuery
		
		# Write-Host "Debug: hasNextPage = $($response.data.site.products.pageInfo.hasNextPage) | Cursor = $($response.data.site.products.pageInfo.endCursor)"

		# Drill down into the data
		$bcProducts = $response.data.site.products.edges

		foreach ($productEdge in $bcProducts) {
			$p = $productEdge.node
			$productCount++
			
			# Only audit products we have in stock
			if ($p.availability -eq "Available") {
				if ($p.inventory.isInStock) {
					$allBcWeights += [PSCustomObject]@{
						Entity      = $p.entityId
						SKU         = $p.sku
						Name        = $p.name
						weightUnit  = $p.weight.unit
						weightValue = $p.weight.value
						inStock     = $p.inventory.isInStock
					}
				} else {
					# Write-Host "SKU: $($p.sku) NOT in stock."
				}		
			}			
		}
		
		# Check if there's another page
		$hasNextPage = $response.data.site.products.pageInfo.hasNextPage
		$endCursor   = $response.data.site.products.pageInfo.endCursor

		if ($productCount % 500 -eq 0) {
			Write-Host "Collected $($productCount) Products so far..."
		}
	}

	Write-Host "Collected $($productCount) Products."
	
	# Final Report
	Write-Host "`nAudit Complete!" -ForegroundColor Green
	Write-Host "Products Found: $($allBcWeights.Count)"
	
	$outputFile = $outputFolderPath + "ProductWeights" + $timestamp + ".csv"
	
	$allBcWeights | Where-Object {$_.weightValue -lt 1 } | Sort-Object SKU | Export-Csv -Path $outputFile -NoTypeInformation
	Write-Host "Results exported to $outputFile" -ForegroundColor Yellow
} elseif ($selection -eq "3") {
	$allBcProducts   = @{} # hash table of products, key is product code; value is inactive
	$sqlFilePath = "$PSScriptRoot\Queries\GetInactiveCelerantProducts.sql"
	
	Write-Host "Fetching all products from BigCommerce (this may take a minute)..." -ForegroundColor Cyan

	while ($hasNextPage) {
		# If we have a cursor, we tell GraphQL where to start the next page
		$after = if ($endCursor) { "after: `"$endCursor`"" } else { "" }
		
		# 2. Define the GraphQL Query
		# This asks for 50 products and their SKU
		$graphQuery = @{
			query = "query {
				site {
					products (first: 50 $after) {
						pageInfo { hasNextPage endCursor }
						edges {
							node {
								entityId
								name
								inventory {
									isInStock
								}
								sku
							}
						}
					}
				}
			}"
		} | ConvertTo-Json
		
		$headers = @{
			"Authorization" = "Bearer $token"
			"Content-Type"  = "application/json"
		}

		$response = Invoke-RestMethod -Uri $url -Method Post -Headers $headers -Body $graphQuery
		
		# Drill down into the data
		$bcProducts = $response.data.site.products.edges

		foreach ($productEdge in $bcProducts) {
			$p = $productEdge.node
			$productCount++
			
			if ($p.sku) {
				$allBcProducts[$p.sku] = [PSCustomObject]@{
						Entity          = $p.entityId
						SKU             = $p.sku
						Name            = $p.name
						inStock         = $p.inventory.isInStock
						Inactive        = $false
						Has_Dupe_Styles = 'N'
					}	
			} else {
				# Write-Host "No SKU from entity: $($p.entityId)"
			}			
		}
		
		# Check if there's another page
		$hasNextPage = $response.data.site.products.pageInfo.hasNextPage
		$endCursor   = $response.data.site.products.pageInfo.endCursor

		if ($productCount % 500 -eq 0) {
			Write-Host "Collected $($productCount) Products so far..."
		}
	}

	Write-Host "Collected $($productCount) Products."

	# Connect to Celerant Database
	Write-Host "Connecting to Celerant Database..." -ForegroundColor Cyan

	# Set up SQL parameters
	$sqlParams = @{
		ServerInstance         = $config.Celerant.ServerInstance
		Database               = $config.Celerant.Database
		InputFile              = $sqlFilePath
		Username               = $config.Celerant.Username
		Password               = $config.Celerant.Password
		Encrypt                = "Mandatory"
		TrustServerCertificate = $true
	}

	try {
		$posData = Invoke-Sqlcmd @sqlParams
		
		Write-Host "Processing data..." -ForegroundColor Cyan
		
		$notFoundInBC = 0
		$foundInBC = 0

		foreach ($row in $posData) {
			$style       = $row.Style
			$productName = $row.Description
			$dept        = $row.Dept
			$season      = $row.Season
			$inactive    = $row.Inactive
			$dupeStyles  = $row.'Has_Dupe_Styles'
			
			if ([string]::IsNullOrWhiteSpace($style)) {
				continue
			}
			
			if ($allBcProducts.ContainsKey($style)) {
				$foundInBC++
				
				$allBcProducts[$style].Inactive = $true
				$allBcProducts[$style].Has_Dupe_Styles = $dupeStyles
			} else {
				$notFoundInBC++
			}
		}

		# Final Report
		Write-Host "`nAudit Complete!" -ForegroundColor Green
		
		$outputFile = $outputFolderPath + "InactiveProducts" + $timestamp + ".csv"
		
		if ($allBcProducts.Count -gt 0) {
			$allBcProducts.Values | Where-Object { $_.Inactive -eq $true } | Sort-Object SKU | Export-Csv -Path $outputFile -NoTypeInformation
			Write-Host "Results exported to $outputFile" -ForegroundColor Yellow
		}
	} catch {
		Write-Host "SQL Error: $_" -ForegroundColor DarkRed
	}
} elseif ($selection -eq "4") {
	$InputFile = "Input\BigCommerceProducts.txt"
	$ScriptBigCommerceProducts = "Queries\BigCommerceProducts.sql"
	$ScriptProductsNotInBC     = "Queries\ProductsNotInBigCommerce.sql"
	
	if (Test-Path $InputFile) {
		Write-Host "Reading products list from $InputFile..." -ForegroundColor Cyan
		
		# Clean data natively in memory: trim spaces, tabs, quotes, and remove empty rows
		$CleanProducts = Get-Content -Path $InputFile | ForEach-Object {
			# Strips out quotes, literal tabs, spaces, and trims ends
			$_.Replace('"', '').Replace("`t", "").Replace(" ", "").Trim()
		} | Where-Object { $_ -ne "" }
		
		Write-Host "Total products found in file: $($CleanProducts.Count)"
		Write-Host "Fetching data from SQL Server..."
		
		$BatchSize   = 300
		$MatchedSKUs = [System.Collections.Generic.List[string]]::new()
		$BatchCount  = 0
		
		for ($i = 0; $i -lt $CleanProducts.Count; $i += $BatchSize) {
			# Grab a clean array slice of up to 300 items
			$BatchArray = $CleanProducts[$i..($i + $BatchSize - 1)] | Where-Object { $_ -ne $null }
			
			# Turn into a SQL-safe string format: 'prod1','prod2','prod3'
			$ProductsParamString = ($BatchArray | ForEach-Object { "'$_'" }) -join ","

			$BatchSqlParams = @{
				ServerInstance         = $config.Celerant.ServerInstance
				Database               = $config.Celerant.Database
				Username               = $config.Celerant.Username
				Password               = $config.Celerant.Password
				InputFile              = $ScriptBigCommerceProducts
				Variable               = @("Products=$ProductsParamString")
				Encrypt                = "Mandatory"
				TrustServerCertificate = $true
			}
			
			# Run the command with our explicit hash table
			$BatchResult = Invoke-Sqlcmd @BatchSqlParams

			# Collect resulting StyleIDs/SKUs into our matched array list
			if ($BatchResult) {
				foreach ($Row in $BatchResult) {
					# Drops values cleanly into memory (automatically avoids --- dashes or spacing issues)
					if ($Row[0]) { $MatchedSKUs.Add("('$($Row[0])')") }
				}
			}

			$BatchCount++
			Write-Host "Processed batch $BatchCount..."
		}
		
		if ($MatchedSKUs.Count -gt 0) {
			Write-Host "Assembling unified SQL transaction in memory..." -ForegroundColor Cyan
			
			# We use a .NET StringBuilder to fast-track appending thousands of string components
			$SqlScriptBuilder = [System.Text.StringBuilder]::new()

			# Append the initial table creation configuration script block
			[void]$SqlScriptBuilder.AppendLine("SET NOCOUNT ON;")
			[void]$SqlScriptBuilder.AppendLine("IF OBJECT_ID('tempdb..##BigCommerceList') IS NOT NULL DROP TABLE ##BigCommerceList;")
			[void]$SqlScriptBuilder.AppendLine("CREATE TABLE ##BigCommerceList (StyleID VARCHAR(255));")

			# Dynamically loop and build all our multi-row INSERT queries straight into memory
			for ($j = 0; $j -lt $MatchedSKUs.Count; $j += $BatchSize) {
				$InsertSlice = $MatchedSKUs[$j..($j + $BatchSize - 1)] | Where-Object { $_ -ne $null }
				
				# Force clean and guarantee syntax safety ('Value') for every item
				$ValuesString = ($InsertSlice | ForEach-Object {
					$RawCode = $_.ToString().Replace("(", "").Replace(")", "").Replace("'", "").Trim()
					"('$RawCode')"
				}) -join ","
				
				# Append this batch line to our overall script sequence
				[void]$SqlScriptBuilder.AppendLine("INSERT INTO ##BigCommerceList (StyleID) VALUES $ValuesString;")
			}

			# Append your final lookup query file directly to the very tail end of the transaction script
			Write-Host "Appending final comparison query script payload..." -ForegroundColor Cyan
			$FinalQueryText = Get-Content -Path $ScriptProductsNotInBC -Raw
			[void]$SqlScriptBuilder.AppendLine($FinalQueryText)

			# Base configuration parameters dictionary
			$QuerySqlParams = @{
				ServerInstance         = $config.Celerant.ServerInstance
				Database               = $config.Celerant.Database
				Username               = $config.Celerant.Username
				Password               = $config.Celerant.Password
				Query                  = $SqlScriptBuilder.ToString() # Hand over the whole unified script payload!
				Encrypt                = "Mandatory"
				TrustServerCertificate = $true
				QueryTimeout           = 600                          # Gives large comparisons plenty of execution time
			}

			Write-Host "Executing transaction on SQL Server (This may take a moment)..." -ForegroundColor Yellow
			
			# Fire everything off at once! The table creation, population, and final SELECT all run in 1 session.
			$FinalResults = Invoke-Sqlcmd @QuerySqlParams

			$OutputFile  = "Output\ProductsNotInBigCommerce_" + $timestamp + ".csv"
			
			# Export data objects smoothly straight to your output destination
			if ($FinalResults) {
				Write-Host "`nAudit Complete!" -ForegroundColor Green
				Write-Host "Products Found: $($FinalResults.Count)"
	
				$FinalResults | Export-Csv -Path $OutputFile -NoTypeInformation -Delimiter "," -Encoding utf8
			} else {
				Write-Warning "Comparison complete, but no missing products were found."
			}

		} else {
			Write-Warning "No product codes matched your Celerant Database during processing."
		}
	}
} else {
	Write-Host "Exiting..." -ForegroundColor Cyan
}