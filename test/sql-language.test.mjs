import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import vm from 'node:vm';
const language = vm.createContext({});
vm.runInContext(readFileSync(new URL('../editor/sql-language.js',import.meta.url),'utf8'),language);
const catalog = [{schema:'public',name:'people',type:'table'},{schema:'public',name:'orders',type:'table'},{schema:'sales',name:'Order Details',type:'view'}];
const definitions = Object.fromEntries(catalog.map(object=>[language.objectKey(object),{columns:[{name:'id',type:'integer'},{name:object.name==='orders'?'person_id':'name',type:'text'},{name:'odd ] " ` column',type:'text'}]}]));
function complete(marked,dialect='postgres',objects=catalog,metadata=definitions,explicit=true) {
  const cursor=marked.indexOf('|');
  return language.complete(language.analyze(marked.replace('|',''),dialect),cursor,objects,metadata,dialect,explicit);
}
const plain = value => JSON.parse(JSON.stringify(value));
test('SQL highlighting preserves source positions and distinguishes comments, literals, identifiers, variables, numbers and dialect words',()=>{
  const sql="SELECT [from], @x, N'it''s <b>&', 12.5e-2 -- SELECT\n/* outer /* nested */ comment */ GETDATE()";
  const parsed=language.analyze(sql,'sqlserver');
  for(const token of parsed.tokens) assert.equal(sql.slice(token.start,token.end),token.text);
  assert.equal(parsed.tokens.find(t=>t.text==='SELECT').kind,'keyword');
  assert.equal(parsed.tokens.find(t=>t.text==='[from]').kind,'identifier');
  assert.equal(parsed.tokens.find(t=>t.text==='@x').kind,'variable');
  assert.equal(parsed.tokens.find(t=>t.text.includes("it''s")).kind,'string');
  assert.equal(parsed.tokens.find(t=>t.text==='12.5e-2').kind,'number');
  assert.equal(parsed.tokens.find(t=>t.text==='GETDATE').kind,'function');
  assert.equal(parsed.tokens.filter(t=>t.kind==='comment').length,2);
  assert.equal(parsed.lines.length,2);
});
test('dialect literals and unterminated strings or comments block suggestions',()=>{
  for(const [sql,dialect] of [["SELECT 'SE|",'postgres'],['SELECT $$JOIN people p; SE|$$','postgres'],['SELECT $tag$SE|$tag$','postgres'],["SELECT E'a\\'SE|",'postgres'],['SELECT -- SE|','sqlserver'],['SELECT /* SE|','sqlserver'],['SELECT # SE|','mysql'],['SELECT "SE|"','mysql']]) {
    assert.equal(complete(sql,dialect).blocked,true,sql);
  }
  assert(complete("SELECT 'ok'; SE|",'postgres').items.some(i=>i.label==='SELECT'));
});
test('keyword and function completion is filtered and dialect-aware',()=>{
  assert(complete('sel|').items.some(i=>i.insertText==='SELECT'));
  assert(complete('GETD|','azure_sql').items.some(i=>i.insertText==='GETDATE'));
  assert(!complete('GETD|','postgres').items.some(i=>i.insertText==='GETDATE'));
  assert.equal(complete('s|','postgres',catalog,definitions,false).items.length,0);
});
test('FROM and schema-qualified completion inserts safely quoted table and view names',()=>{
  assert.equal(complete('SELECT * FROM pe|').items.find(i=>i.label==='people').insertText,'"public"."people"');
  assert.equal(complete('SELECT * FROM public.pe|').items.find(i=>i.label==='people').insertText,'"people"');
  assert.equal(complete('SELECT * FROM [sales].[Order D|]','sqlserver').items.find(i=>i.label==='Order Details').insertText,'[Order Details]');
  assert.equal(complete('SELECT * FROM sales.|','mysql').items.find(i=>i.label==='Order Details').insertText,'`Order Details`');
});
test('alias and joined-table column suggestions use only the current statement, including FROM after the cursor',()=>{
  let result=complete('SELECT p.na| FROM public.people AS p JOIN public.orders o ON o.person_id=p.id');
  assert.equal(result.items.find(i=>i.label==='name').insertText,'"name"');
  assert.equal(result.items.filter(i=>i.kind!=='column').length,0);
  assert(!complete('SELECT * FROM people p; SELECT p.|').items.some(i=>i.kind==='column'));
  assert.equal(complete('SELECT i| FROM people p JOIN orders o ON p.id=o.person_id').items.filter(i=>i.label==='id').length,2);
  assert.equal(complete('SELECT p.| FROM people p JOIN orders o ON p.id=o.person_id').items.filter(i=>i.label==='id').length,1);
});
test('metadata is requested only for unambiguous referenced catalog objects and bounded per request',()=>{
  let result=complete('SELECT p.| FROM people p','postgres',catalog,{});
  assert.deepEqual(plain(result.missing),[catalog[0]]);
  assert.equal(result.loading,true);
  result=complete('SELECT p.| FROM people p','postgres',catalog,{[language.objectKey(catalog[0])]:{loading:true}});
  assert.equal(result.missing.length,0);
  assert.equal(result.loading,true);
  const duplicate=catalog.concat([{schema:'other',name:'people'}]);
  assert.equal(complete('SELECT p.| FROM people p','postgres',duplicate,{}).missing.length,0);
  assert.equal(complete('SELECT p.| FROM otherdb.public.people p','postgres',catalog,{}).missing.length,0);
  assert.equal(complete('SELECT p.| FROM people p','postgres',catalog,{[language.objectKey(catalog[0])]:{error:true}}).unavailable,true);
  const many=Array.from({length:10},(_,i)=>({schema:'public',name:'t'+i}));
  assert.equal(complete('SELECT | FROM '+many.map((o,i)=>o.name+' a'+i).join(' JOIN '),'postgres',many,{}).missing.length,4);
});
test('CTEs never borrow columns from a catalog table with the same name',()=>{
  assert.equal(complete('WITH people AS (SELECT 1 x) SELECT p.| FROM people p').items.length,0);
});
test('replacement spans include the whole token while preserving the rest of the SQL',()=>{
  const sql='SELECT na|me FROM people';
  const result=complete(sql);
  assert.equal(sql.replace('|','').slice(result.start,result.end),'name');
  assert.equal(result.prefix,'na');
  assert.equal(language.quote('a]b','sqlserver'),'[a]]b]');
  assert.equal(language.quote('a"b','postgres'),'"a""b"');
  assert.equal(language.quote('a`b','mysql'),'`a``b`');
});
test('highlight paint segments are plain source text and omit the native selection',()=>{
  const parsed=language.analyze("SELECT\t'<tag>'\n-- comment\n\nSELECT 2",'postgres');
  const ranges=parsed.lines.map(l=>({start:l.start,end:l.end}));
  const segments=language.paintSegments(parsed,ranges,2,9);
  for(const segment of segments) {
    assert.equal(segment.text,parsed.text.slice(segment.start,segment.start+segment.text.length));
    assert(segment.start>=9 || segment.start+segment.text.length<=2);
    assert(!segment.text.includes('\n'));
  }
  assert.equal(language.lineAt(parsed,parsed.text.length),3);
});
