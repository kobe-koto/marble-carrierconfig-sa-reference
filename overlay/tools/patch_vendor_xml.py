#!/usr/bin/env python3
"""Generate CarrierConfig vendor.xml variants that enable NR SA."""
import argparse, copy, json
from pathlib import Path
from xml.etree import ElementTree as ET

SA_AVAILABLE = 'carrier_sa_mode_available_bool'
DISABLE_SA = 'carrier_disable_sa_mode_bool'
DISABLE_VICE_SA = 'carrier_disable_vice_sa_mode_bool'
NR_AVAIL = 'carrier_nr_availabilities_int_array'

def children_named(cfg, name):
    return [x for x in list(cfg) if x.get('name') == name]

def set_bool(cfg, name, value):
    matches = children_named(cfg, name)
    if matches:
        node = matches[0]
        node.tag = 'boolean'
        node.attrib.clear(); node.set('name', name); node.set('value', 'true' if value else 'false')
        for extra in matches[1:]: cfg.remove(extra)
        return False
    cfg.append(ET.Element('boolean', {'name': name, 'value': 'true' if value else 'false'}))
    return True

def ensure_nr_array(cfg, force_nsa=True, force_sa=True):
    matches = children_named(cfg, NR_AVAIL)
    created = not matches
    if matches:
        node = matches[0]
        for extra in matches[1:]: cfg.remove(extra)
    else:
        node = ET.Element('int-array', {'name': NR_AVAIL, 'num': '0'})
        cfg.append(node)
    values=[]
    for item in list(node):
        if item.tag == 'item' and item.get('value') is not None:
            v=item.get('value')
            if v not in values: values.append(v)
    if force_nsa and '1' not in values: values.append('1')
    if force_sa and '2' not in values: values.append('2')
    for child in list(node): node.remove(child)
    node.tag='int-array'; node.attrib.clear(); node.set('name',NR_AVAIL); node.set('num',str(len(values)))
    for v in values: node.append(ET.Element('item', {'value':v}))
    return created, values

def selectors(cfg):
    return dict(cfg.attrib)

def indent_xml(elem, level=0):
    pad='    '*level
    if len(elem):
        if elem.text is None or not elem.text.strip(): elem.text='\n'+'    '*(level+1)
        for i,ch in enumerate(elem):
            indent_xml(ch,level+1)
            ch.tail='\n'+('    '*(level+1) if i+1<len(elem) else pad)
    elif elem.text is None: elem.text=None

def main():
    ap=argparse.ArgumentParser()
    ap.add_argument('--mode', choices=['explicit-nsa','universal'], required=True)
    ap.add_argument('input', type=Path)
    ap.add_argument('output', type=Path)
    ap.add_argument('--report', type=Path)
    a=ap.parse_args()
    root=ET.parse(a.input).getroot()
    configs=[x for x in root if x.tag=='carrier_config']
    touched=[]

    appended_overrides = 0
    if a.mode=='explicit-nsa':
        # The vendor file contains late selector-less defaults that overwrite
        # earlier MCC/MNC blocks. Discover explicit NSA selectors from the
        # original blocks, then append final matching blocks so our values win
        # in the parser's document-order putAll() merge.
        explicit_nsa_selectors=[]
        for cfg in configs:
            arrays=children_named(cfg,NR_AVAIL)
            vals=[i.get('value') for arr in arrays for i in arr if i.tag=='item']
            if '1' in vals:
                sel=selectors(cfg)
                if sel not in explicit_nsa_selectors:
                    explicit_nsa_selectors.append(sel)
        for sel in explicit_nsa_selectors:
            override=ET.Element('carrier_config', sel)
            ensure_nr_array(override)
            set_bool(override,SA_AVAILABLE,True)
            set_bool(override,DISABLE_SA,False)
            set_bool(override,DISABLE_VICE_SA,False)
            root.append(override)
            configs.append(override)
            touched.append(sel)
            appended_overrides += 1
    else:
        # Patch every existing explicit override so no carrier-specific rule can
        # re-disable SA after the global defaults are applied.
        for cfg in configs:
            changed=False
            for name,val in ((SA_AVAILABLE,True),(DISABLE_SA,False),(DISABLE_VICE_SA,False)):
                if children_named(cfg,name): set_bool(cfg,name,val); changed=True
            if children_named(cfg,NR_AVAIL): ensure_nr_array(cfg); changed=True
            if changed: touched.append(selectors(cfg))
        # There are two selector-less vendor default blocks in this ROM. Apply
        # the combined SA+NSA default to both; carrier-specific values above are
        # already normalized to prevent them from overriding this default.
        for cfg in configs:
            if cfg.attrib: continue
            set_bool(cfg,SA_AVAILABLE,True)
            set_bool(cfg,DISABLE_SA,False)
            set_bool(cfg,DISABLE_VICE_SA,False)
            ensure_nr_array(cfg)
            if selectors(cfg) not in touched: touched.append(selectors(cfg))

    indent_xml(root)
    a.output.parent.mkdir(parents=True,exist_ok=True)
    ET.ElementTree(root).write(a.output,encoding='utf-8',xml_declaration=True,short_empty_elements=True)
    report={
      'mode':a.mode,
      'carrier_config_blocks':len(configs),
      'touched_blocks':len(touched),
      'appended_override_blocks':appended_overrides,
      'touched_selectors':touched,
      'sa_available_true_count':sum(1 for c in configs for x in children_named(c,SA_AVAILABLE) if x.get('value')=='true'),
      'disable_sa_false_count':sum(1 for c in configs for x in children_named(c,DISABLE_SA) if x.get('value')=='false'),
      'disable_vice_sa_false_count':sum(1 for c in configs for x in children_named(c,DISABLE_VICE_SA) if x.get('value')=='false'),
      'nr_arrays_with_sa_count':sum(1 for c in configs for x in children_named(c,NR_AVAIL) if '2' in [i.get('value') for i in x]),
    }
    if a.report:
        a.report.parent.mkdir(parents=True,exist_ok=True)
        a.report.write_text(json.dumps(report,indent=2,ensure_ascii=False)+'\n')
    print(json.dumps(report,ensure_ascii=False))

if __name__=='__main__': main()
