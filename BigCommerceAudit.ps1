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
Write-Host "4. Exit" -ForegroundColor Cyan
$selection = Read-Host "Enter your selection"

if ($selection -eq "1") {
	$allBcPrices    = @{} # A 'Hash Table' to store SKU => Price for fast lookup
	
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
		Write-Host "`nComparison Complete!" -ForegroundColor Green
		Write-Host "Mismatches Found: $($mismatches.Count)"
		Write-Host "SKUs in POS but missing in BC: $notFoundInBC"
		
		if ($mismatches.Count -gt 0) {
			$mismatches | Sort-Object SKU | Export-Csv -Path $outputFolderPath + "PriceMismatches.csv" -NoTypeInformation
			Write-Host "Results exported to Output\PriceMismatches.csv" -ForegroundColor Yellow
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

	# Final Report
	Write-Host "`nAudit Complete!" -ForegroundColor Green
	Write-Host "Products Found: $($allBcWeights.Count)"
		
	$allBcWeights | Where-Object {$_.weightValue -lt 1 } | Sort-Object SKU | Export-Csv -Path $outputFolderPath + "ProductWeights.csv" -NoTypeInformation
	Write-Host "Results exported to Output\ProductWeights.csv" -ForegroundColor Yellow
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
						Entity      = $p.entityId
						SKU         = $p.sku
						Name        = $p.name
						inStock     = $p.inventory.isInStock
						Inactive    = $false
					}	
			} else {
				# Write-Host "No SKU from entity: $($p.entityId)"
			}			
		}
		
		# Check if there's another page
		$hasNextPage = $response.data.site.products.pageInfo.hasNextPage
		$endCursor   = $response.data.site.products.pageInfo.endCursor

		if ($productCount % 500 -eq 0) {
			Write-Host "Collected $($allBcProducts.Count) SKUs from $($productCount) Products so far..."
		}
	}

	Write-Host "Total: Collected $($allBcProducts.Count) SKUs from $($productCount) Products."

	# Connect to Celerant Database
	Write-Host "Connecting to Celerant Database and comparing prices..." -ForegroundColor Cyan

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
		
		$notFoundInBC = 0
		$foundInBC = 0

		foreach ($row in $posData) {
			$style       = $row.Style
			$productName = $row.Description
			$dept        = $row.Dept
			$season      = $row.Season
			$inactive    = $row.Inactive
			
			if ([string]::IsNullOrWhiteSpace($style)) {
				continue
			}
			
			if ($allBcProducts.ContainsKey($style)) {
				$foundInBC++
				
				$allBcProducts[$style].Inactive = $true
			} else {
				$notFoundInBC++
			}
		}

		# Final Report
		Write-Host "`nComparison Complete!" -ForegroundColor Green
		Write-Host "SKUs in POS but missing in BC: $notFoundInBC"
		
		if ($allBcProducts.Count -gt 0) {
			$allBcProducts.Values | Where-Object { $_.Inactive -eq $true } | Sort-Object SKU | Export-Csv -Path $outputFolderPath + "InactiveProducts.csv" -NoTypeInformation
			Write-Host "Results exported to Output\InactiveProducts.csv" -ForegroundColor Yellow
		}
	} catch {
		Write-Host "SQL Error: $_" -ForegroundColor DarkRed
	} 
} else {
	Write-Host "Exiting..." -ForegroundColor Cyan
}