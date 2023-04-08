import requests
from bs4 import BeautifulSoup

url = 'https://down.idc.wiki/Image/realServer-Template/'

response = requests.get(url)
soup = BeautifulSoup(response.text, 'html.parser')

for li in soup.find_all('li', {'class': 'item file'}):
    link = li.find('a')['href'].replace("cdn-backblaze.down.idc.wiki//Image/realServer-Template/", "").replace("//", "")
    print(link,end=" ")
