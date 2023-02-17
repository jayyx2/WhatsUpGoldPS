$webhookURL = "https://discord.com/api/webhooks/1073829428360138762/aGyQQg7zX5Yha-8Wf-hkNHoj-RWpwKfCVbO4nmpGgewBhd48wmltVFK8GPFls_BlgCmC"

$author = New-Object -TypeName PSObject -Property @{
    name = 'Progress WhatsUp Gold'
    url = 'https://www.whatsupgold.com'
    icon_url = 'https://docs.ipswitch.com/NM/WhatsUpGold2018/03_Help/1033/LogoWUG164x50.png'
}

$field1 = New-Object -TypeName PSObject -Property @{
    name = 'Text'
    value = 'More text'
    inline = $true
}

$field2 = New-Object -TypeName PSObject -Property @{
    name = 'Even more text'
    value = 'Yup'
    inline = $true
}

$field3 = New-Object -TypeName PSObject -Property @{
    name = 'Use `"inline": true` parameter, if you want to display fields in the same line.'
    value = 'okay...'
    inline = $true
}

$field4 = New-Object -TypeName PSObject -Property @{
    name = 'Thanks!'
    value = "You're welcome :wink:"
    inline = $true
}

$fields = @($field1, $field2, $field3, $field4)

$thumbnail = New-Object -TypeName PSObject -Property @{
    url = 'https://community.progress.com/s/products/whatsup-gold'
}

$image = New-Object -TypeName PSObject -Property @{
    url = 'https://docs.ipswitch.com/NM/WhatsUpGold2018/03_Help/1033/LogoWUG164x50.png'
}

$footer = New-Object -TypeName PSObject -Property @{
    text = 'Sent by Progress WhatsUp Gold'
    icon_url = 'https://docs.ipswitch.com/NM/WhatsUpGold2018/03_Help/1033/LogoWUG164x50.png'
}

$embed = New-Object -TypeName PSObject -Property @{
    author = $author
    title = 'Clickable title here'
    url = 'https://google.com/'
    #description = 'Text message. You can use Markdown here. *Italic* **bold** __underline__ ~~strikeout~~ [Hyperlink](https://google.com) `code`'
    description = "OK"
    color = 15258703
    fields = $fields
    thumbnail = $thumbnail
    image = $image
    footer = $footer
}

$payload = @{
  'username' = 'Webhook'
  'avatar_url' = 'https://i.imgur.com/4M34hi2.png'
  'content' = ''
  'embeds' = @($embed)
} | ConvertTo-Json -Depth 10

Invoke-RestMethod -Method Post -Uri $webhookURL -Body $payload -ContentType 'application/json'