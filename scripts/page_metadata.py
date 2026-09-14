"""Parse inert HTML metadata supplied on stdin. Never fetch or execute page content."""
from html.parser import HTMLParser
import sys,json
class Metadata(HTMLParser):
 def __init__(self):super().__init__(convert_charrefs=True);self.values={};self.in_title=False;self.title=[]
 def handle_starttag(self,tag,attrs):
  a=dict(attrs)
  if tag.lower()=='meta':
   name=(a.get('name')or a.get('property')or'').lower();value=a.get('content','').strip()
   if name and value:self.values.setdefault(name,[]).append(value)
  if tag.lower()=='title':self.in_title=True
 def handle_endtag(self,tag):
  if tag.lower()=='title':self.in_title=False
 def handle_data(self,data):
  if self.in_title:self.title.append(data)
p=Metadata();p.feed(sys.stdin.read());v=p.values
fields={}
for field,keys in {'title':['citation_title','dc.title','og:title'],'doi':['citation_doi','dc.identifier','dc.identifier.doi'],'abstract':['citation_abstract','dc.description','description','og:description'],'year':['citation_publication_date','citation_date','dc.date'],'journal':['citation_journal_title'],'publisher':['citation_publisher','dc.publisher'],'volume':['citation_volume'],'number':['citation_issue'],'pages':['citation_firstpage'],'pdf':['citation_pdf_url']}.items():
 for key in keys:
  if v.get(key):fields[field]=v[key][0];break
if not fields.get('title'):fields['title']=''.join(p.title).strip()
a=v.get('citation_author')or v.get('dc.creator')or[]
if a:fields['author']=' and '.join(a)
if 'year'in fields:fields['year']=fields['year'][:4]
print(json.dumps(fields))
