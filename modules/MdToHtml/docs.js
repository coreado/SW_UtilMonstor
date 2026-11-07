// 목차 검색 + 현재 장 강조 (기존 계획서 HTML에서 가져옴)
const search=document.querySelector('#search'),links=[...document.querySelectorAll('#nav a')];search.addEventListener('input',()=>{const q=search.value.toLocaleLowerCase('ko').trim();let visible=0;for(const a of links){const yes=a.textContent.toLocaleLowerCase('ko').includes(q);a.classList.toggle('hide',!yes);if(yes)visible++}document.getElementById('empty').style.display=visible?'none':'block'});const observer=new IntersectionObserver(entries=>{for(const e of entries){if(e.isIntersecting){links.forEach(a=>a.classList.toggle('active',a.getAttribute('href')==='#'+e.target.id));}}},{rootMargin:'-12% 0px -74% 0px'});document.querySelectorAll('.chapter').forEach(s=>observer.observe(s));

// 자동변환(감시) 중일 때만: MD가 저장되면 이 페이지를 자동으로 새로고침
(function(){
  var name=document.body.dataset.reload; if(!name) return;
  var stamp=null, seen=false;
  function poll(){
    var s=document.createElement('script');
    s.src=name+'?t='+Date.now();
    s.onload=function(){
      s.remove(); seen=true;
      if(stamp===null) stamp=window.__mdStamp;
      else if(window.__mdStamp!==stamp){ location.reload(); return; }
      setTimeout(poll,1000);
    };
    s.onerror=function(){ s.remove(); if(seen) setTimeout(poll,3000); };
    document.head.appendChild(s);
  }
  poll();
})();
