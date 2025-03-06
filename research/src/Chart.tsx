import React, { useRef, useEffect } from 'react';
import * as d3 from 'd3';

export const D3Chart: React.FC<{
  data: any[];
  specialPoints: any[];
  virtualBalances: { virtualBalanceA: number; virtualBalanceB: number };
}> = ({ data, specialPoints, virtualBalances }) => {
  const svgRef = useRef<SVGSVGElement>(null);

  useEffect(() => {
    if (!svgRef.current || !data.length) return;

    const renderChart = () => {
      // Clear previous chart
      d3.select(svgRef.current).selectAll('*').remove();

      // Set up dimensions
      const svgElement = svgRef.current;
      const containerWidth = svgElement?.parentElement?.clientWidth ?? 800;
      const width = containerWidth;
      const height = 600;
      const margin = { top: 40, right: 40, bottom: 60, left: 60 };
      const innerWidth = width - margin.left - margin.right;
      const innerHeight = height - margin.top - margin.bottom;

      // Create scales
      const xScale = d3
        .scaleLinear()
        .domain([d3.min(data, (d) => d.x)!, d3.max(data, (d) => d.x)!])
        .range([0, innerWidth]);

      const yScale = d3
        .scaleLinear()
        .domain([d3.min(data, (d) => d.y)!, d3.max(data, (d) => d.y)!])
        .range([innerHeight, 0]);

      // Create SVG
      const svg = d3
        .select(svgRef.current)
        .attr('width', width)
        .attr('height', height)
        .append('g')
        .attr('transform', `translate(${margin.left},${margin.top})`);

      // Add grid
      svg
        .append('g')
        .attr('class', 'grid')
        .attr('opacity', 0.1)
        .call(
          d3
            .axisBottom(xScale)
            .tickSize(innerHeight)
            .tickFormat(() => '')
        )
        .call((g) => g.select('.domain').remove());

      svg
        .append('g')
        .attr('class', 'grid')
        .attr('opacity', 0.1)
        .call(
          d3
            .axisLeft(yScale)
            .tickSize(-innerWidth)
            .tickFormat(() => '')
        )
        .call((g) => g.select('.domain').remove());

      // Add axes
      svg.append('g').attr('transform', `translate(0,${innerHeight})`).call(d3.axisBottom(xScale));

      svg.append('g').call(d3.axisLeft(yScale));

      // Add reference lines
      svg
        .append('line')
        .attr('x1', xScale(virtualBalances.virtualBalanceA))
        .attr('x2', xScale(virtualBalances.virtualBalanceA))
        .attr('y1', 0)
        .attr('y2', innerHeight)
        .attr('stroke', '#BBBBBB')
        .attr('stroke-width', 2);

      svg
        .append('line')
        .attr('x1', 0)
        .attr('x2', innerWidth)
        .attr('y1', yScale(virtualBalances.virtualBalanceB))
        .attr('y2', yScale(virtualBalances.virtualBalanceB))
        .attr('stroke', '#BBBBBB')
        .attr('stroke-width', 2);

      // Add curve
      const line = d3
        .line<any>()
        .x((d) => xScale(d.x))
        .y((d) => yScale(d.y));

      svg
        .append('path')
        .datum(data)
        .attr('fill', 'none')
        .attr('stroke', '#8884d8')
        .attr('stroke-width', 2)
        .attr('d', line);

      // Add special points
      svg
        .selectAll('.point-special')
        .data(specialPoints.slice(0, 2))
        .enter()
        .append('circle')
        .attr('class', 'point-special')
        .attr('cx', (d) => xScale(d.x))
        .attr('cy', (d) => yScale(d.y))
        .attr('r', 5)
        .attr('fill', 'red');

      // Add current point
      svg
        .append('circle')
        .datum(specialPoints[2])
        .attr('cx', (d) => xScale(d.x))
        .attr('cy', (d) => yScale(d.y))
        .attr('r', 5)
        .attr('fill', 'green');

      // Add margin points
      svg
        .selectAll('.point-margin')
        .data(specialPoints.slice(3, 5))
        .enter()
        .append('circle')
        .attr('class', 'point-margin')
        .attr('cx', (d) => xScale(d.x))
        .attr('cy', (d) => yScale(d.y))
        .attr('r', 5)
        .attr('fill', 'blue');

      // Add axis labels
      svg
        .append('text')
        .attr('x', innerWidth / 2)
        .attr('y', innerHeight + 40)
        .attr('text-anchor', 'middle')
        .text('Total Balance A');

      svg
        .append('text')
        .attr('transform', 'rotate(-90)')
        .attr('x', -innerHeight / 2)
        .attr('y', -40)
        .attr('text-anchor', 'middle')
        .text('Total Balance B');
    };

    renderChart();

    // Set up resize observer
    const resizeObserver = new ResizeObserver(() => {
      renderChart();
    });

    if (svgRef.current.parentElement) {
      resizeObserver.observe(svgRef.current.parentElement);
    }

    // Cleanup
    return () => {
      resizeObserver.disconnect();
    };
  }, [data, specialPoints, virtualBalances]);

  return <svg ref={svgRef}></svg>;
};
