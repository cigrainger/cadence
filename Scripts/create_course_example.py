"""Rebuild the original chapter PDF from the same notes loaded by the app."""
from pathlib import Path
import json
from reportlab.pdfgen import canvas
from reportlab.pdfbase import pdfmetrics
from reportlab.pdfbase.ttfonts import TTFont
from reportlab.lib.colors import HexColor
ROOT=Path(__file__).resolve().parents[1]
MUSIC=ROOT/'Resources/ImportExamples'
scores=json.loads((MUSIC/'chapter-scores.json').read_text())
pdfmetrics.registerFont(TTFont('MusicSymbols','/System/Library/Fonts/Apple Symbols.ttf'))
c=canvas.Canvas(str(MUSIC/'chapter.pdf'),pagesize=(612,792))
c.setTitle('A first chapter: notes, pulse and space'); c.setAuthor('Cadence original learning material')
ink=HexColor('#243437'); moss=HexColor('#3D6658'); muted=HexColor('#73817B')
def text(x,y,value,size=12,font='Helvetica',color=ink):
 c.setFillColor(color); c.setFont(font,size); c.drawString(x,y,value)
def lines(y,values):
 for value in values: text(54,y,value); y-=19
 return y
def page(n,kicker,title):
 c.setFillColor(HexColor('#F8F7F0')); c.rect(0,0,612,792,fill=1,stroke=0)
 text(54,743,'cadence',24,'Times-Bold',moss); text(54,699,kicker,10,'Helvetica-Bold',muted)
 text(54,665,title,26,'Times-Bold'); c.setStrokeColor(moss); c.line(54,643,558,643)
 text(54,35,'Original example chapter - freely reusable with Cadence',9,color=muted); text(546,35,str(n),10,color=muted)
page(1,'ONE REVIEWED CHAPTER','Notes, pulse and space')
y=lines(609,['A small piano chapter for learning how to read, keep a pulse,', 'and leave room for silence. Take one phrase at a time.'])
text(54,537,'01  Find a comfortable pulse',17,'Times-Bold')
lines(509,['Count 1, 2, 3, 4 evenly. Tap once on each number, then keep', 'counting while you imagine the taps. A click can help you begin.'])
text(54,436,'02  Small steps, steady pulse',17,'Times-Bold')
lines(408,['Read the four bars on page 2. Middle C is the first note.', 'Listen, locate the notes, then play slowly with your right hand.', 'The left hand rests. If a note is uncertain, remove the time pressure.'])
text(54,316,'03  Make room for the spaces',17,'Times-Bold')
lines(288,['Page 3 mixes quarter notes, half notes and rests. Count through', 'each space. A rest is part of the phrase, not a cue to stop counting.'])
text(54,216,'Try an idea of your own',17,'Times-Bold')
lines(188,['When the first phrase feels familiar, choose a different final note.', 'Listen to its effect. Does it sound settled, or as if it wants to continue?', 'This variation is an invitation to explore, not a scored test.'])
text(54,93,'Suggested start: 60 bpm, 4/4, one short visit at a time.',11,color=moss)
c.showPage()
# Staff y is the bottom line; treble middle C is one ledger line below it.
steps={60:-2,62:-1,64:0,65:1,67:2}
for index,score in enumerate(scores):
 page(index+2,'EXERCISE '+str(index+1),score['title'])
 lines(607,['Piano - right hand. Left hand rests. 4/4, quarter note = 60.', 'Read each written bar once. Count through notes and rests.'])
 for system in range(2):
  top=480-system*190; bottom=top-85; left=54; start=115; barw=215
  c.setStrokeColor(ink); c.setLineWidth(.6)
  for staff in [top,bottom]:
   for line in range(5): c.line(left,staff+line*7,558,staff+line*7)
  c.line(left, bottom,left,top+28)
  text(59,top-7,'\U0001D11E',45,'MusicSymbols'); text(59,bottom+5,'\U0001D122',32,'MusicSymbols')
  for staff in [top,bottom]:
   text(94,staff+14,'4',13,'Times-Bold'); text(94,staff+1,'4',13,'Times-Bold')
  for b in range(2):
   bar=system*2+b; x0=start+b*barw
   text(x0+5,top+43,str(bar+1),10,color=muted)
   beat=0
   for note in score['bars'][bar]:
    x=x0+21+beat*46; ticks=note['ticks']; midi=note['midi']
    if midi<0:
     if ticks==960:
      c.setFillColor(ink); c.rect(x-4,top+14,8,3,fill=1,stroke=0)
     else:
      # Draw a quarter rest directly; system music fonts do not all have this glyph.
      p=c.beginPath(); p.moveTo(x-2,top+28); p.lineTo(x+3,top+22); p.lineTo(x-2,top+16); p.lineTo(x+3,top+10)
      c.setLineWidth(2.5); c.drawPath(p,stroke=1); c.setLineWidth(0.6)
      c.circle(x-1,top+8,2.1,fill=1,stroke=0)
      p=c.beginPath(); p.moveTo(x+3,top+10); p.curveTo(x-6,top+13,x-5,top+3,x+1,top+2); c.drawPath(p,stroke=1)
    else:
     y=top+steps[midi]*3.5
     c.setFillColor(ink); c.ellipse(x-4.5,y-3,x+4.5,y+3,fill=int(ticks==480),stroke=1)
     c.line(x+4.5,y,x+4.5,y+24)
     if midi==60: c.line(x-7,y,x+7,y)
    beat+=ticks/480
   # Whole-bar rest hangs from the fourth staff line.
   c.setFillColor(ink); c.rect(x0+93,bottom+18,10,3,fill=1,stroke=0)
   c.line(x0+barw,bottom,x0+barw,top+28)
  if system==1:
   c.setLineWidth(2); c.line(547,bottom,547,top+28); c.setLineWidth(.6)
 text(54,155,'After playing',15,'Times-Bold',moss)
 lines(130,['Name one thing that became easier and one place to revisit.', 'Then try again another day, with less help if that feels comfortable.'])
 c.showPage()
c.save()
print(MUSIC/'chapter.pdf')
